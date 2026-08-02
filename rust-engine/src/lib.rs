//! Tantivy-backed lexical engine for Search My Mac.
//!
//! The C ABI is deliberately JSON-based at the process boundary. Swift owns
//! discovery and protected-file access; this library owns only the derived
//! lexical index. No function allows arbitrary filesystem reads.

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::path::Path;
use std::ptr;
use std::sync::Arc;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tantivy::collector::TopDocs;
use tantivy::query::QueryParser;
use tantivy::schema::{
    Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, STORED, STRING,
    TantivyDocument, Value,
};
use tantivy::{Index, IndexReader, IndexWriter, ReloadPolicy, Term, doc};
use thiserror::Error;

const WRITER_HEAP_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Error)]
enum EngineError {
    #[error("invalid UTF-8 at the FFI boundary")]
    InvalidUtf8,
    #[error("invalid JSON request: {0}")]
    Json(#[from] serde_json::Error),
    #[error("search index error: {0}")]
    Tantivy(#[from] tantivy::TantivyError),
    #[error("query error: {0}")]
    Query(#[from] tantivy::query::QueryParserError),
    #[error("required index field is missing: {0}")]
    MissingField(&'static str),
}

#[derive(Clone, Copy)]
struct Fields {
    source_id: Field,
    passage_id: Field,
    body: Field,
    filename: Field,
    title: Field,
    path: Field,
    modified_at: Field,
    availability: Field,
    generation: Field,
}

pub struct Engine {
    index: Index,
    reader: IndexReader,
    writer: Mutex<IndexWriter>,
    fields: Fields,
}

#[derive(Debug, Deserialize)]
pub struct UpsertRequest {
    pub source_id: String,
    pub generation: i64,
    pub filename: String,
    pub title: String,
    pub path: String,
    pub modified_at: i64,
    pub availability: String,
    pub passages: Vec<PassageInput>,
}

#[derive(Debug, Deserialize)]
pub struct PassageInput {
    pub passage_id: u64,
    pub body: String,
}

#[derive(Debug, Deserialize)]
pub struct SearchRequest {
    pub query: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    50
}

#[derive(Debug, Serialize, Clone)]
pub struct PassageHit {
    pub passage_id: u64,
    pub body: String,
    pub score: f32,
}

#[derive(Debug, Serialize)]
pub struct SearchHit {
    pub source_id: String,
    pub filename: String,
    pub path: String,
    pub availability: String,
    pub modified_at: i64,
    pub score: f32,
    pub passages: Vec<PassageHit>,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub hits: Vec<SearchHit>,
}

impl Engine {
    fn open(index_path: &Path) -> Result<Self, EngineError> {
        std::fs::create_dir_all(index_path).map_err(tantivy::TantivyError::from)?;
        let index = if index_path.join("meta.json").exists() {
            Index::open_in_dir(index_path)?
        } else {
            Index::create_in_dir(index_path, build_schema())?
        };
        let fields = fields_from_schema(index.schema())?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::OnCommitWithDelay)
            .try_into()?;
        let writer = index.writer(WRITER_HEAP_BYTES)?;
        Ok(Self {
            index,
            reader,
            writer: Mutex::new(writer),
            fields,
        })
    }

    fn upsert(&self, request: UpsertRequest) -> Result<(), EngineError> {
        let writer = self.writer.lock();
        writer.delete_term(Term::from_field_text(self.fields.source_id, &request.source_id));

        let passages = if request.passages.is_empty() {
            vec![PassageInput {
                passage_id: 0,
                body: String::new(),
            }]
        } else {
            request.passages
        };
        for passage in passages {
            writer.add_document(doc!(
                self.fields.source_id => request.source_id.clone(),
                self.fields.passage_id => passage.passage_id,
                self.fields.body => passage.body,
                self.fields.filename => request.filename.clone(),
                self.fields.title => request.title.clone(),
                self.fields.path => request.path.clone(),
                self.fields.modified_at => request.modified_at,
                self.fields.availability => request.availability.clone(),
                self.fields.generation => request.generation,
            ))?;
        }
        Ok(())
    }

    fn delete(&self, source_id: &str) {
        self.writer
            .lock()
            .delete_term(Term::from_field_text(self.fields.source_id, source_id));
    }

    fn commit(&self) -> Result<u64, EngineError> {
        let opstamp = self.writer.lock().commit()?;
        self.reader.reload()?;
        Ok(opstamp)
    }

    fn search(&self, request: SearchRequest) -> Result<SearchResponse, EngineError> {
        let searcher = self.reader.searcher();
        let mut parser = QueryParser::for_index(
            &self.index,
            vec![
                self.fields.body,
                self.fields.filename,
                self.fields.title,
                self.fields.path,
            ],
        );
        parser.set_field_boost(self.fields.filename, 5.0);
        parser.set_field_boost(self.fields.title, 3.0);
        parser.set_field_boost(self.fields.body, 1.0);
        parser.set_field_boost(self.fields.path, 0.7);
        let query = parser.parse_query(&request.query)?;
        let candidate_count = request.limit.clamp(1, 200) * 8;
        let top_docs = searcher.search(
            &query,
            &TopDocs::with_limit(candidate_count).order_by_score(),
        )?;

        let mut groups: HashMap<String, Group> = HashMap::new();
        for (score, address) in top_docs {
            let document: TantivyDocument = searcher.doc(address)?;
            let source_id = text(&document, self.fields.source_id).unwrap_or_default();
            if source_id.is_empty() {
                continue;
            }
            let entry = groups.entry(source_id.clone()).or_insert_with(|| Group {
                source_id,
                filename: text(&document, self.fields.filename).unwrap_or_default(),
                path: text(&document, self.fields.path).unwrap_or_default(),
                availability: text(&document, self.fields.availability).unwrap_or_default(),
                modified_at: integer(&document, self.fields.modified_at).unwrap_or_default(),
                passages: Vec::new(),
            });
            entry.passages.push(PassageHit {
                passage_id: unsigned(&document, self.fields.passage_id).unwrap_or_default(),
                body: text(&document, self.fields.body).unwrap_or_default(),
                score,
            });
        }

        let mut hits: Vec<SearchHit> = groups
            .into_values()
            .map(|mut group| {
                group.passages.sort_by(|a, b| b.score.total_cmp(&a.score));
                group.passages.truncate(3);
                let score = aggregate_score(&group.passages);
                SearchHit {
                    source_id: group.source_id,
                    filename: group.filename,
                    path: group.path,
                    availability: group.availability,
                    modified_at: group.modified_at,
                    score,
                    passages: group.passages,
                }
            })
            .collect();
        hits.sort_by(|a, b| b.score.total_cmp(&a.score));
        hits.truncate(request.limit.clamp(1, 200));
        Ok(SearchResponse { hits })
    }
}

struct Group {
    source_id: String,
    filename: String,
    path: String,
    availability: String,
    modified_at: i64,
    passages: Vec<PassageHit>,
}

fn build_schema() -> Schema {
    let mut builder = Schema::builder();
    let body_options = TextOptions::default()
        .set_stored()
        .set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("default")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions),
        );
    let text_options = TextOptions::default().set_stored().set_indexing_options(
        TextFieldIndexing::default()
            .set_tokenizer("default")
            .set_index_option(IndexRecordOption::WithFreqsAndPositions),
    );
    builder.add_text_field("source_id", STRING | STORED);
    builder.add_u64_field("passage_id", STORED);
    builder.add_text_field("body", body_options);
    builder.add_text_field("filename", text_options.clone());
    builder.add_text_field("title", text_options.clone());
    builder.add_text_field("path", text_options);
    builder.add_i64_field("modified_at", STORED);
    builder.add_text_field("availability", STRING | STORED);
    builder.add_i64_field("generation", STORED);
    builder.build()
}

fn fields_from_schema(schema: Schema) -> Result<Fields, EngineError> {
    let get = |name, error| schema.get_field(name).map_err(|_| EngineError::MissingField(error));
    Ok(Fields {
        source_id: get("source_id", "source_id")?,
        passage_id: get("passage_id", "passage_id")?,
        body: get("body", "body")?,
        filename: get("filename", "filename")?,
        title: get("title", "title")?,
        path: get("path", "path")?,
        modified_at: get("modified_at", "modified_at")?,
        availability: get("availability", "availability")?,
        generation: get("generation", "generation")?,
    })
}

fn text(document: &TantivyDocument, field: Field) -> Option<String> {
    document
        .get_first(field)
        .and_then(|value| value.as_str())
        .map(ToOwned::to_owned)
}

fn integer(document: &TantivyDocument, field: Field) -> Option<i64> {
    document.get_first(field).and_then(|value| value.as_i64())
}

fn unsigned(document: &TantivyDocument, field: Field) -> Option<u64> {
    document.get_first(field).and_then(|value| value.as_u64())
}

fn aggregate_score(passages: &[PassageHit]) -> f32 {
    passages
        .iter()
        .enumerate()
        .map(|(index, passage)| {
            let weight = match index {
                0 => 1.0,
                1 => 0.15,
                _ => 0.05,
            };
            passage.score * weight
        })
        .sum()
}

fn string_argument<'a>(pointer: *const c_char) -> Result<&'a str, EngineError> {
    if pointer.is_null() {
        return Err(EngineError::InvalidUtf8);
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| EngineError::InvalidUtf8)
}

fn json_result<T: Serialize>(result: Result<T, EngineError>) -> *mut c_char {
    #[derive(Serialize)]
    struct Envelope<T> {
        ok: bool,
        value: Option<T>,
        error: Option<String>,
    }
    let envelope = match result {
        Ok(value) => Envelope {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => Envelope {
            ok: false,
            value: None,
            error: Some(error.to_string()),
        },
    };
    let json = serde_json::to_string(&envelope).unwrap_or_else(|_| {
        "{\"ok\":false,\"value\":null,\"error\":\"serialization failure\"}".to_owned()
    });
    CString::new(json).map_or(ptr::null_mut(), CString::into_raw)
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_engine_open(path: *const c_char) -> *mut Engine {
    let Ok(path) = string_argument(path) else {
        return ptr::null_mut();
    };
    match Engine::open(Path::new(path)) {
        Ok(engine) => Arc::into_raw(Arc::new(engine)) as *mut Engine,
        Err(_) => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_engine_retain(engine: *mut Engine) -> *mut Engine {
    if engine.is_null() {
        return ptr::null_mut();
    }
    unsafe { Arc::increment_strong_count(engine) };
    engine
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_engine_release(engine: *mut Engine) {
    if !engine.is_null() {
        unsafe { drop(Arc::from_raw(engine)) };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_engine_upsert(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    let result = (|| {
        let engine = unsafe { engine.as_ref() }.ok_or(EngineError::InvalidUtf8)?;
        let request = serde_json::from_str::<UpsertRequest>(string_argument(json)?)?;
        engine.upsert(request)?;
        Ok(())
    })();
    json_result(result)
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_engine_delete(engine: *mut Engine, source_id: *const c_char) -> *mut c_char {
    let result = (|| {
        let engine = unsafe { engine.as_ref() }.ok_or(EngineError::InvalidUtf8)?;
        engine.delete(string_argument(source_id)?);
        Ok(())
    })();
    json_result(result)
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_engine_commit(engine: *mut Engine) -> *mut c_char {
    let result = unsafe { engine.as_ref() }
        .ok_or(EngineError::InvalidUtf8)
        .and_then(Engine::commit);
    json_result(result)
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_engine_search(engine: *mut Engine, json: *const c_char) -> *mut c_char {
    let result = (|| {
        let engine = unsafe { engine.as_ref() }.ok_or(EngineError::InvalidUtf8)?;
        let request = serde_json::from_str::<SearchRequest>(string_argument(json)?)?;
        engine.search(request)
    })();
    json_result(result)
}

#[unsafe(no_mangle)]
pub extern "C" fn smm_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe { drop(CString::from_raw(value)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indexes_groups_and_ranks_passages() {
        let path = std::env::temp_dir().join(format!("searchmymac-rust-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        let engine = Engine::open(&path).unwrap();
        engine
            .upsert(UpsertRequest {
                source_id: "budget".into(),
                generation: 1,
                filename: "Quarterly Budget.docx".into(),
                title: "Quarterly Budget".into(),
                path: "/Documents/Quarterly Budget.docx".into(),
                modified_at: 0,
                availability: "available".into(),
                passages: vec![PassageInput {
                    passage_id: 1,
                    body: "The research allocation increased this quarter.".into(),
                }],
            })
            .unwrap();
        engine.commit().unwrap();
        let response = engine
            .search(SearchRequest {
                query: "research allocation".into(),
                limit: 10,
            })
            .unwrap();
        assert_eq!(response.hits.len(), 1);
        assert_eq!(response.hits[0].source_id, "budget");
        let _ = std::fs::remove_dir_all(path);
    }
}
