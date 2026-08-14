//! Bounded anydoc adapter for Search My Mac.
//!
//! Swift owns protected-file access and passes already-read bytes across this
//! C ABI. The adapter never accepts a path and never executes document content.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;

use anydoc::model::{Block, CellSlot, Document, inlines_to_plain_text};
use anydoc::{ConvertError, Format};
use pdf_inspector::PdfError;
use serde::Serialize;

const MAX_INPUT_BYTES: usize = 100 * 1_024 * 1_024;
const MAX_OUTPUT_CHARACTERS: usize = 20_000_000;

#[derive(Debug)]
struct ExtractionFailure {
    code: &'static str,
    message: String,
}

#[derive(Serialize)]
struct ExtractionOutput {
    text: String,
}

#[derive(Serialize)]
struct PdfPageOutput {
    page_index: u32,
    text: String,
    needs_ocr: bool,
}

#[derive(Serialize)]
struct PdfExtractionOutput {
    pages: Vec<PdfPageOutput>,
}

#[derive(Serialize)]
struct Envelope<T> {
    ok: bool,
    value: Option<T>,
    error_code: Option<&'static str>,
    error: Option<String>,
}

fn extract_bytes(bytes: &[u8], extension: &str) -> Result<ExtractionOutput, ExtractionFailure> {
    if bytes.len() > MAX_INPUT_BYTES {
        return Err(ExtractionFailure {
            code: "resourceLimit",
            message: "document exceeds the parser input limit".into(),
        });
    }
    let format = Format::from_bytes(bytes)
        .or_else(|| Format::from_extension(extension))
        .ok_or_else(|| ExtractionFailure {
            code: "unsupported",
            message: format!("unsupported document format: {extension}"),
        })?;
    if format == Format::Pdf {
        return Err(ExtractionFailure {
            code: "unsupported",
            message: "use the page-aware PDF extraction entry point".into(),
        });
    }
    let document = anydoc::to_document(bytes, format).map_err(map_conversion_error)?;
    let plain_text = document_to_plain_text(&document);
    let text = if plain_text.chars().count() > MAX_OUTPUT_CHARACTERS {
        plain_text.chars().take(MAX_OUTPUT_CHARACTERS).collect()
    } else {
        plain_text
    };
    Ok(ExtractionOutput { text })
}

fn extract_pdf_bytes(bytes: &[u8]) -> Result<PdfExtractionOutput, ExtractionFailure> {
    if bytes.len() > MAX_INPUT_BYTES {
        return Err(ExtractionFailure {
            code: "resourceLimit",
            message: "PDF exceeds the parser input limit".into(),
        });
    }
    let result = pdf_inspector::extract_pages_markdown_mem(bytes, None).map_err(map_pdf_error)?;
    let mut remaining_characters = MAX_OUTPUT_CHARACTERS;
    let pages = result
        .pages
        .into_iter()
        .map(|page| PdfPageOutput {
            page_index: page.page,
            text: cap_text(
                markdown_to_plain_text(&page.markdown),
                &mut remaining_characters,
            ),
            needs_ocr: page.needs_ocr,
        })
        .collect();
    Ok(PdfExtractionOutput { pages })
}

fn cap_text(text: String, remaining_characters: &mut usize) -> String {
    let character_count = text.chars().count();
    if character_count <= *remaining_characters {
        *remaining_characters -= character_count;
        text
    } else {
        let capped = text.chars().take(*remaining_characters).collect();
        *remaining_characters = 0;
        capped
    }
}

fn map_conversion_error(error: ConvertError) -> ExtractionFailure {
    let code = match &error {
        ConvertError::Unsupported(_) => "unsupported",
        ConvertError::Malformed { .. } => "malformed",
        ConvertError::Encrypted => "encrypted",
        ConvertError::ResourceLimit { .. } => "resourceLimit",
        ConvertError::MissingPart { .. } => "missingPart",
        ConvertError::Io(_) => "io",
        _ => "conversion",
    };
    ExtractionFailure {
        code,
        message: error.to_string(),
    }
}

fn map_pdf_error(error: PdfError) -> ExtractionFailure {
    let code = match &error {
        PdfError::Encrypted => "encrypted",
        PdfError::Io(_) => "io",
        PdfError::NotAPdf(_) | PdfError::InvalidStructure | PdfError::Parse(_) => "malformed",
    };
    ExtractionFailure {
        code,
        message: error.to_string(),
    }
}

fn document_to_plain_text(document: &Document) -> String {
    let mut output = String::new();
    append_blocks(&document.blocks, &mut output);
    for note in &document.notes {
        append_blocks(&note.blocks, &mut output);
    }
    output.trim().to_owned()
}

fn append_blocks(blocks: &[Block], output: &mut String) {
    for block in blocks {
        let mut rendered = String::new();
        match block {
            Block::Heading { content, .. } | Block::Paragraph(content) => {
                rendered = inlines_to_plain_text(content);
            }
            Block::List(list) => {
                for (offset, item) in list.items.iter().enumerate() {
                    let mut body = String::new();
                    append_blocks(&item.blocks, &mut body);
                    let marker = item.marker_label.clone().unwrap_or_else(|| {
                        list.marker.label(list.start.saturating_add(offset as u64))
                    });
                    let body = body.trim();
                    if !body.is_empty() {
                        if !rendered.is_empty() {
                            rendered.push('\n');
                        }
                        rendered.push_str(&marker);
                        rendered.push(' ');
                        rendered.push_str(body);
                    }
                }
            }
            Block::Table(table) => {
                for row in &table.grid {
                    let cells: Vec<String> = row
                        .iter()
                        .map(|slot| match slot {
                            CellSlot::Origin(cell) => {
                                let mut text = String::new();
                                append_blocks(&cell.blocks, &mut text);
                                text.split_whitespace().collect::<Vec<_>>().join(" ")
                            }
                            CellSlot::Covered { .. } => String::new(),
                        })
                        .collect();
                    if cells.iter().any(|cell| !cell.is_empty()) {
                        if !rendered.is_empty() {
                            rendered.push('\n');
                        }
                        rendered.push_str(&cells.join("\t"));
                    }
                }
            }
            Block::BlockQuote(nested) => append_blocks(nested, &mut rendered),
            Block::CodeBlock { text, .. } => rendered.push_str(text),
            Block::Rule => {}
        }
        append_section(output, rendered.trim());
    }
}

fn append_section(output: &mut String, section: &str) {
    if section.is_empty() {
        return;
    }
    if !output.is_empty() {
        output.push_str("\n\n");
    }
    output.push_str(section);
}

fn markdown_to_plain_text(markdown: &str) -> String {
    let mut output = String::new();
    for raw_line in markdown.lines() {
        let mut line = raw_line.trim();
        if line.is_empty() || is_markdown_table_separator(line) {
            continue;
        }
        line = line.trim_start_matches('#').trim_start();
        line = line.trim_start_matches('>').trim_start();
        let rendered = if line.starts_with('|') && line.ends_with('|') {
            line.trim_matches('|')
                .split('|')
                .map(|cell| strip_inline_markdown(cell.trim()))
                .collect::<Vec<_>>()
                .join("\t")
        } else {
            strip_inline_markdown(line)
        };
        append_section(&mut output, rendered.trim());
    }
    output
}

fn is_markdown_table_separator(line: &str) -> bool {
    line.contains('|')
        && line
            .chars()
            .all(|character| matches!(character, '|' | '-' | ':' | ' ' | '\t'))
}

fn strip_inline_markdown(value: &str) -> String {
    let mut text = value.to_owned();
    while let Some(label_start) = text.find('[') {
        let Some(label_end_offset) = text[label_start + 1..].find("](") else {
            break;
        };
        let label_end = label_start + 1 + label_end_offset;
        let Some(target_end_offset) = text[label_end + 2..].find(')') else {
            break;
        };
        let target_end = label_end + 2 + target_end_offset;
        let label = text[label_start + 1..label_end].to_owned();
        let replacement_start = label_start.saturating_sub(usize::from(
            label_start > 0 && text.as_bytes()[label_start - 1] == b'!',
        ));
        text.replace_range(replacement_start..=target_end, &label);
    }
    let mut without_tags = String::with_capacity(text.len());
    let mut inside_tag = false;
    let mut escaped = false;
    for character in text.chars() {
        if escaped {
            without_tags.push(character);
            escaped = false;
            continue;
        }
        match character {
            '\\' => escaped = true,
            '<' => inside_tag = true,
            '>' if inside_tag => inside_tag = false,
            _ if !inside_tag => without_tags.push(character),
            _ => {}
        }
    }
    for marker in ["**", "~~", "`", "*"] {
        remove_paired_markers(&mut without_tags, marker);
    }
    without_tags
}

fn remove_paired_markers(text: &mut String, marker: &str) {
    while let Some(start) = text.find(marker) {
        let after_start = start + marker.len();
        let Some(end_offset) = text[after_start..].find(marker) else {
            break;
        };
        let end = after_start + end_offset;
        text.replace_range(end..end + marker.len(), "");
        text.replace_range(start..after_start, "");
    }
}

fn extension_argument<'a>(pointer: *const c_char) -> Result<&'a str, ExtractionFailure> {
    if pointer.is_null() {
        return Err(ExtractionFailure {
            code: "invalidInput",
            message: "missing document extension".into(),
        });
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| ExtractionFailure {
            code: "invalidInput",
            message: "document extension is not valid UTF-8".into(),
        })
}

fn result_json<T: Serialize>(result: Result<T, ExtractionFailure>) -> *mut c_char {
    let envelope = match result {
        Ok(value) => Envelope {
            ok: true,
            value: Some(value),
            error_code: None,
            error: None,
        },
        Err(failure) => Envelope {
            ok: false,
            value: None,
            error_code: Some(failure.code),
            error: Some(failure.message),
        },
    };
    let json = serde_json::to_string(&envelope).unwrap_or_else(|_| {
        "{\"ok\":false,\"value\":null,\"error_code\":\"serialization\",\"error\":\"serialization failure\"}".into()
    });
    CString::new(json).map_or(ptr::null_mut(), CString::into_raw)
}

/// Extract searchable plain text from document bytes.
///
/// The returned UTF-8 JSON string must be released with
/// [`smm_extractor_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn smm_anydoc_extract(
    bytes: *const u8,
    length: usize,
    extension: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if bytes.is_null() && length != 0 {
            return Err(ExtractionFailure {
                code: "invalidInput",
                message: "missing document bytes".into(),
            });
        }
        let bytes = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        extract_bytes(bytes, extension_argument(extension)?)
    }))
    .unwrap_or_else(|_| {
        Err(ExtractionFailure {
            code: "panic",
            message: "document parser aborted while reading malformed content".into(),
        })
    });
    result_json(result)
}

/// Extract page-aware searchable text and OCR-routing hints from PDF bytes.
#[unsafe(no_mangle)]
pub extern "C" fn smm_pdf_extract(bytes: *const u8, length: usize) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if bytes.is_null() && length != 0 {
            return Err(ExtractionFailure {
                code: "invalidInput",
                message: "missing PDF bytes".into(),
            });
        }
        let bytes = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        extract_pdf_bytes(bytes)
    }))
    .unwrap_or_else(|_| {
        Err(ExtractionFailure {
            code: "panic",
            message: "PDF parser aborted while reading malformed content".into(),
        })
    });
    result_json(result)
}

/// Release a string returned by this library.
#[unsafe(no_mangle)]
pub extern "C" fn smm_extractor_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe { drop(CString::from_raw(value)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anydoc::model::{Cell, Inline, List, ListItem, MarkerKind, Table, TableKind};

    #[test]
    fn extracts_rtf_without_markdown_syntax() {
        let rtf = br"{\rtf1\ansi Search My Mac \b parser\b0  fixture}";
        let output = extract_bytes(rtf, "rtf").unwrap();
        assert_eq!(output.text, "Search My Mac parser fixture");
    }

    #[test]
    fn plain_text_preserves_lists_tables_and_notes() {
        let document = Document {
            blocks: vec![
                Block::List(List {
                    marker: MarkerKind::Decimal,
                    start: 3,
                    items: vec![ListItem {
                        blocks: vec![Block::Paragraph(vec![Inline::plain("third item")])],
                        ..Default::default()
                    }],
                }),
                Block::Table(Table::from_rows(
                    vec![vec![
                        Cell::from_inlines(vec![Inline::plain("Alpha")]),
                        Cell::from_inlines(vec![Inline::plain("42")]),
                    ]],
                    0,
                    TableKind::Data,
                )),
            ],
            ..Default::default()
        };
        let text = document_to_plain_text(&document);
        assert!(text.contains("3. third item"));
        assert!(text.contains("Alpha\t42"));
        assert!(!text.contains('|'));
    }

    #[test]
    fn markdown_cleanup_preserves_table_cells_and_link_labels() {
        let text = markdown_to_plain_text(
            "# Report\n\n| Name | Value |\n| --- | ---: |\n| [Alpha](https://example.com) | **42** |",
        );
        assert_eq!(text, "Report\n\nName\tValue\n\nAlpha\t42");
    }

    #[test]
    fn output_cap_counts_unicode_characters_across_pages() {
        let mut remaining = 5;
        assert_eq!(cap_text("Aé日".into(), &mut remaining), "Aé日");
        assert_eq!(remaining, 2);
        assert_eq!(cap_text("BCDE".into(), &mut remaining), "BC");
        assert_eq!(remaining, 0);
        assert_eq!(cap_text("ignored".into(), &mut remaining), "");
    }
}
