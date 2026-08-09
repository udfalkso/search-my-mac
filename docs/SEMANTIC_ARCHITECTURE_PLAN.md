# Semantic Search v2 — Architecture and Implementation Plan

## Goal

Make broad-intent searches such as `home buying related` reliably retrieve documents whose extracted text is structurally noisy, while preserving strong passage-level retrieval for specific questions and phrases.

Semantic Search v2 is a clean replacement for the current passage-only semantic index. It does not migrate old vectors or preserve compatibility with the existing semantic schema. Extracted documents and the lexical index remain reusable because they are independent source data; all semantic-derived state is rebuilt.

## Decisions

1. **Use two semantic representations.** Every eligible document can produce passage vectors and document-concept vectors. Neither representation substitutes for the other.
2. **Use separate passage and document vector indexes.** Querying them independently prevents one unit type from crowding the other out of a shared HNSW candidate set and permits kind-specific ranking.
3. **Use Qwen3 Embedding 4B at 1,024 dimensions.** The focused bake-off showed materially better discrimination than Qwen3 Embedding 0.6B while 1,024-dimensional Matryoshka truncation preserved quality and the current vector width.
4. **Make document understanding an optional enhancement.** Qwen3 0.6B generates bounded descriptions, topics, and likely search phrases when installed. Semantic Search remains fully functional with Qwen3 Embedding 4B passage vectors alone; the optional generator improves broad-intent and life-event queries.
5. **Never show generated text as a quotation from a file.** Search snippets always come from original extracted passages. The UI may state that a result matched by topic, but must not present generated concepts as document content.
6. **Do not strip numbers from source passages.** Dates, amounts, identifiers, dimensions, and spreadsheet values can be meaningful. Generated broad-search hints may reject excessive identifiers, but source extraction and passage embeddings remain lossless apart from whitespace normalization and token limits.
7. **Treat every semantic artifact as derived and versioned.** Model hashes, embedding dimensions, query instruction, passage formatting, generator prompt, concept schema, and ranking version are all part of the semantic format identity.

## Model downloads and feature levels

The models are independently installable, verified components:

| Component | Initial artifact | Purpose |
| --- | --- | --- |
| Semantic Search | Qwen3 Embedding 4B Q4_K_M | Required for semantic queries and passage vectors |
| Enhanced document understanding | Qwen3 0.6B Q8 | Optional generation of document topics and likely-search vectors |

The embedding model is approximately 2.4 GB; enhanced understanding adds approximately 640 MB. Settings and onboarding show each download and its installed-storage estimate before installation. Each file has an exact byte count and SHA-256, downloads to an owner-only staging path, validates before publication, and is atomically renamed.

Feature states are explicit:

| State | Search behavior |
| --- | --- |
| Semantic Search not installed | Text search remains available. Semantic/Hybrid offer installation. |
| Embedding model installed, passage indexing in progress | Semantic and Hybrid search use ready passage vectors immediately. |
| Enhanced understanding not installed | Semantic Search works normally; broad topic and likely-search matches are unavailable. Settings offers `Enhance semantic search…`. |
| Enhanced understanding indexing | Passage search remains available while document-topic coverage grows progressively. |
| Enhanced understanding paused/removed | Existing generated-unit vectors are removed; passage semantic search remains available. |

The model bundle descriptor contains:

- embedding and optional-enhancement component identifiers;
- source URL, exact size, and SHA-256;
- embedding dimensions and truncation method;
- query instruction version;
- passage-input format version;
- generator prompt and output-schema version;
- minimum supported llama.cpp runtime version.

Changing any vector-affecting field creates a new semantic format identity. Search My Mac deletes `Semantic-v2` and rebuilds it instead of attempting mixed-vector compatibility.

### Memory policy

Search responsiveness takes precedence over optional concept generation.

- Keep the embedding model resident while Semantic or Hybrid search is available.
- Load the generator at utility priority only when memory pressure permits.
- Stop and unload the generator immediately on serious memory pressure, application Quit, or model removal.
- Pause concept generation while the user is actively searching if measured query latency exceeds its budget.
- Passage embedding continues even when concept generation is paused, unavailable, or removed.

Before release, test the pair on 8 GB, 16 GB, and 32 GB Apple-silicon systems and the supported Intel baseline. If the 0.6B Q8 generator causes unacceptable pressure, test Q6/Q5/Q4 variants against the judged concept corpus. Do not silently downgrade the embedding model or mix vectors from different models.

## SQLite model

SQLite remains authoritative for semantic work and publication state. Generated concepts are stored so interrupted indexing does not regenerate them, but they remain disposable derived data.

```sql
CREATE TABLE semantic_documents (
    source_id TEXT PRIMARY KEY REFERENCES files(source_id) ON DELETE CASCADE,
    source_generation INTEGER NOT NULL,
    generator_id TEXT NOT NULL,
    generator_format INTEGER NOT NULL,
    summary TEXT,
    generated_at REAL NOT NULL,
    error TEXT
);

CREATE TABLE semantic_units (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id TEXT NOT NULL REFERENCES files(source_id) ON DELETE CASCADE,
    passage_id INTEGER REFERENCES passages(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('passage', 'topic', 'query_hint')),
    ordinal INTEGER NOT NULL,
    body TEXT,
    content_hash TEXT NOT NULL,
    embedding_model_id TEXT,
    embedding_format INTEGER,
    embedded_at REAL,
    UNIQUE(source_id, kind, ordinal)
);

CREATE INDEX semantic_units_pending_idx
    ON semantic_units(embedding_model_id, kind, source_id);

CREATE TABLE semantic_vector_tombstones (
    unit_id INTEGER PRIMARY KEY,
    lane TEXT NOT NULL CHECK(lane IN ('passage', 'document'))
);
```

Passage units reference `passages` and do not duplicate their bodies. `body` is populated only for generated topic and query-hint units. Code should expose a resolved input accessor rather than making callers understand this storage distinction.

`semantic_units.id` is the vector key in its lane. Because passage and document vectors live in separate physical stores, their numeric IDs do not require bit packing or another implicit namespace.

When a source is re-extracted, removed, or excluded:

1. journal every published unit ID into `semantic_vector_tombstones`;
2. replace its desired semantic units in one SQLite transaction;
3. commit SQLite;
4. apply vector tombstones idempotently;
5. generate and embed the new desired units.

A source generation mismatch invalidates both its generated concepts and passage units. A crash at any boundary leaves explicit pending work that can be replayed.

## Document concept generation

### Input construction

Do not feed an arbitrary prefix of the concatenated document to the generator. Build a deterministic, bounded document sample:

1. filename and parent-folder labels;
2. document title and structured metadata, when available;
3. the first informative passage;
4. headings, sheet names, page labels, and other structural anchors;
5. a relevance-neutral sample across the middle and end of long documents;
6. the final informative passage.

Deduplicate repeated headers/footers and collapse whitespace. Retain numbers in the sample. Cap input by tokens, with explicit per-section budgets so a large first page or spreadsheet cannot consume the entire prompt.

Spreadsheet sampling uses workbook and sheet names, header rows, representative categorical cells, and a bounded selection of formulas-as-displayed-text. It does not serialize entire numeric grids. CSV and spreadsheet concept generation remains the lowest scheduling priority.

### Output contract

Use llama.cpp grammar-constrained JSON rather than parsing free-form Markdown:

```json
{
  "summary": "short factual purpose",
  "topics": ["one broad topic", "another broad topic"],
  "likely_queries": ["plain-language phrase", "another phrase"]
}
```

Limits:

- one summary of at most 60 words;
- one to five topics;
- one to five likely queries;
- each topic/query at most 12 words;
- no empty, duplicate, or near-duplicate values;
- bounded UTF-8 output size and generation tokens;
- no names, full addresses, account numbers, or long numeric sequences in likely queries;
- generated claims must remain grounded in the sampled text.

Post-processing normalizes whitespace and removes duplicates. It rejects malformed, identifier-heavy, or unsupported output instead of retrying indefinitely. A failed generator leaves passage semantic search available and records an actionable but non-blocking diagnostic.

Embed each accepted topic and likely query independently. The bake-off showed that a useful individual phrase can be much stronger than the embedding of a verbose card containing that phrase.

## Progressive indexing pipeline

Semantic work has explicit stages and can resume after any interruption:

```text
extracted source
    ├── create passage units ──> passage embeddings ──> passage vector lane
    └── sample document ──> generate concepts ──> concept embeddings ──> document vector lane
```

Scheduling order:

1. recently opened or modified prose documents;
2. recent PDFs and office documents;
3. older prose documents;
4. OCR-derived image documents;
5. CSV and spreadsheet documents;
6. large, low-information, or repeatedly failing sources.

Within a priority tier, distribute work across sources rather than finishing every passage in one large file. Passage indexing should become useful immediately. Concept generation is a separate optional queue and never blocks it.

The worker maintains separate counters:

- documents understood;
- passage units embedded;
- document units embedded;
- failed/deferred documents.

The user-facing UI can collapse these into overall semantic coverage, while Index Health exposes the separate numbers. Completion means all currently eligible desired units are either embedded or in a terminal, visible deferred state.

### Throttling

- User-initiated searches run at user-initiated priority.
- Embedding and generation run at utility priority.
- Background application state reduces batch sizes and inserts measured delays.
- Thermal pressure, battery state, memory pressure, active text indexing, and search latency can independently reduce or pause work.
- Pause stops generation, embedding, snapshot construction, and progress mutation at a bounded cancellation point.

## Vector durability

Create two independent `Semantic-v2` lanes:

```text
Semantic-v2/
    passages/
        vectors.f16
        vectors.manifest.jsonl
        hnsw-current.json
        hnsw-<generation>.usearch
    documents/
        vectors.f16
        vectors.manifest.jsonl
        hnsw-current.json
        hnsw-<generation>.usearch
```

Both lanes retain the existing durability pattern:

- canonical append-only float16 vectors with checksums;
- SQLite-driven tombstones;
- exact search over the unpublished delta;
- immutable memory-mapped int8 USearch snapshots;
- temporary generation, validation, and atomic manifest replacement;
- previous generation retained until the new generation is published.

Int8 remains conditional on recall@10 staying within 2% of float16 for each lane. The document lane must be tested independently because its corpus and score distribution differ from passages.

Rebuild storage estimates include the current and next generation for both lanes. Low-space checks happen before model download, bulk embedding, compaction, and HNSW publication.

## Query and ranking pipeline

Embed the query once with the versioned retrieval instruction. Always search the passage lane; search the document lane only when enhanced understanding is installed and it has published vectors. Over-fetch before applying folder, type, date, availability, and image policies.

```text
query vector
    ├── passage HNSW + exact delta ──> filtered passage candidates
    └── document HNSW + exact delta ──> filtered topic/query candidates
                                      ↓
                        group each lane by source
                                      ↓
                  weighted semantic reciprocal-rank fusion
                                      ↓
                         semantic source ranking
```

When both lanes are available, start semantic-lane fusion at:

- 60% passage evidence;
- 40% document-concept evidence.

If the document lane is unavailable, passage-lane ranking is the complete semantic ranking—not a degraded error state. When both lanes are available, use reciprocal-rank fusion rather than directly comparing raw cosine values whose distributions differ by unit kind. Within a source:

- retain the best passage plus diminishing evidence from at most two additional passages;
- retain the best topic/query-hint rank plus one diminishing secondary concept;
- cap duplicate or near-identical generated concepts;
- never allow five generated paraphrases to count as five independent confirmations.

Hybrid mode then performs its existing second-stage fusion between lexical source ranking and the completed semantic source ranking. Exact filenames, identifiers, quoted phrases, rare proper nouns, and strong all-term lexical matches retain lexical priority.

Do not add a universal cosine cutoff based on this single regression case. If low-confidence suppression is needed, calibrate it per lane on the judged corpus and include a safe minimum-result policy.

## Result materialization

All result IDs remain source IDs, never filenames. Duplicate filenames in different paths remain independently selectable.

For a passage-lane match, show the best original matching passages as today. For a document-concept-only match:

1. prefer an original passage from the same source that also appeared in passage candidates;
2. otherwise select the source's first structurally informative passage;
3. optionally show a quiet `Matched by topic` label;
4. never highlight or quote generated text as though it came from the file.

Quick Look, Open, Reveal in Finder, filters, pagination, history, saved searches, and the CLI all operate on the grouped source result and therefore require no separate concept-result UX.

Pagination cursors include the semantic ranking version and both vector-generation IDs. Retire or invalidate a cursor cleanly if either generation is no longer available.

## App, CLI, and XPC boundaries

- The resident app continues to own file access and passes extracted text/metadata into the engine boundary.
- Model execution and vector mutation belong in the authenticated engine service when the production data path moves behind XPC.
- The extractor never receives model access and the models never receive arbitrary filesystem paths to open.
- `smm` opens the passage lane and SQLite read-only, then also opens the document lane when available. It generates one query vector and uses the same ranking code and format identity as the app.
- CLI Semantic/Hybrid mode requires the embedding model and passage lane. It reports `enhanced_semantic: false` when the optional document lane is unavailable; it never starts background generation.

Generated summaries, topics, likely queries, embeddings, and prompts remain local. Diagnostic logs record unit IDs, timings, token counts, model versions, and error categories—not queries, generated content, snippets, or full paths.

## UI changes

### Semantic settings

- Present `Semantic Search` as the primary local feature and `Enhanced document understanding` as an optional add-on.
- Show the separate download size, installed size, and estimated index size for each.
- Explain that semantic search works from document passages; the add-on improves searches phrased as broad concepts or life events.
- Preserve independent Pause, Resume, Remove, and retry controls. Removing the enhancement must not disable semantic passage search.

### Search

- Semantic and Hybrid become available after at least one searchable passage source, whether or not the enhancement is installed.
- When the enhancement is absent, offer a dismissible `Enhance semantic search` tip only in Semantic/Hybrid mode. When it is indexing, distinguish `Passage search ready; document understanding is still growing`.
- Auto-hide the tip only when both eligible passage and document coverage exceed 90%, or the user hides it.

### Index Health

Show user-facing categories:

- semantic model storage;
- passage semantic storage;
- document-understanding storage;
- passage coverage;
- optional document-understanding coverage;
- deferred/failed semantic files.

Keep model IDs, vector dimensions, HNSW, SQLite, checksums, and ranking constants out of the default UI. Include them only in an explicitly exported diagnostic bundle.

## Failure and recovery behavior

| Failure | Behavior |
| --- | --- |
| Optional generator fails, is absent, or times out | Keep passage search; record document understanding as deferred/unavailable; bounded manual retry |
| Embedding fails | Leave unit pending with attempt metadata; back off; do not block other sources |
| Source changes during generation | Discard output using source generation/identity check and requeue |
| Model verification fails | Do not publish; remove staging file; explain retry |
| Low disk | Pause before writes/rebuild; preserve current published generations |
| Crash during append | Replay from SQLite desired units; checksums reject partial vector payloads |
| Crash during snapshot build | Ignore temporary generation; retain current manifest |
| Memory pressure | Cancel/unload generator first; preserve search model when possible |
| External root offline | Retain concepts/vectors and mark source offline; do not infer deletion |

## Implementation sequence

### 1. Relevance harness and contracts

- Promote `semantic-benchmark` into a repeatable fixture-driven tool.
- Add JSON input/output with query, source, representations, cosine values, ranks, and timings.
- Create an initial judged corpus spanning PDFs, prose, screenshots/OCR, email, spreadsheets, code-like noise, finance, healthcare, travel, and duplicate/near-duplicate files.
- Freeze the v2 model bundle and prompt only after baseline measurements are reproducible.

### 2. Semantic manifest v2

- Add `semantic_documents`, `semantic_units`, and lane-aware tombstones.
- Add source-generation invalidation and transactional desired-unit replacement.
- Add tests for deletion, re-extraction, exclusion, root removal, crash replay, and duplicate filenames.
- Introduce `Semantic-v2` storage and deliberately discard old semantic vectors on first use.

### 3. Independent model manager

- Support the required embedding model and optional generator as independently verified components.
- Add independent install/remove, download progress, and disk estimates.
- Add memory-pressure-aware loading and clean cancellation.
- Validate Qwen3 4B 1,024-dimensional output against the official reference implementation.

### 4. Concept generation

- Implement deterministic document sampling by format.
- Implement grammar-constrained JSON output and validation.
- Persist concepts by source generation and prompt version.
- Add corrupt, adversarial, identifier-heavy, extremely long, and multilingual fixtures.

### 5. Dual-lane vector pipeline

- Generalize the existing durable vector store into named lanes.
- Index passage and document units independently.
- Publish and recover independent immutable snapshots.
- Add storage reporting and low-disk tests for two simultaneous rebuilds.

### 6. Retrieval and ranking

- Search both lanes and group by source.
- Add weighted semantic RRF, then reuse Hybrid lexical/semantic fusion.
- Materialize only original snippets.
- Add generation-aware cursors and filter tests.
- Route the app and `smm` through the identical ranking implementation.

### 7. Product integration

- Update settings, coverage messaging, Index Health, diagnostics, and independent model removal.
- Ensure Pause and Quit cancel every v2 pipeline stage.
- Rebuild the app bundle and verify model/framework runtime paths and signing.

### 8. Quality and release gates

- Tune only against the versioned judged corpus.
- Run long-duration indexing, crash injection, memory pressure, thermal, battery, low-disk, sleep/wake, and offline-root tests.
- Verify Apple-silicon and Intel behavior before claiming support.

## Acceptance gates

The architecture is ready to replace v1 only when all of the following hold:

- Passage-only Qwen3 4B meets the existing semantic baseline before the optional enhancement is enabled.
- Enabling enhanced understanding improves broad-intent subset NDCG@10 by at least 15% over passage-only Qwen3 4B.
- Overall semantic NDCG@10 improves by at least 10%.
- Exact/identifier/quoted-query quality in Hybrid declines by no more than 2%.
- Document concepts improve the judged broad-intent subset and do not increase irrelevant OCR/screenshot results by more than 2%.
- Qwen3 4B at 1,024 dimensions remains within 2% recall@10 of its full 2,560-dimensional output.
- Int8 HNSW recall@10 remains within 2% of float16 exact search in each lane.
- Warm Semantic and Hybrid p95 remain below the existing 250 ms Apple-silicon and 500 ms Intel targets after models are resident.
- Search latency remains within budget while background concept generation runs.
- Forced crashes never publish partial vectors or require manual repair.
- Removing or reindexing a source leaves no searchable stale semantic unit.
- No generated text appears as a quoted source snippet or leaves the Mac.
- Model and index storage estimates are within 10% of observed usage on the benchmark corpus, separately for core Semantic Search and the optional enhancement.

## Files expected to change

- `Sources/SearchMyMacCore/SemanticModel.swift`: bundle descriptors, model loading, generator, structured output.
- `Sources/SearchMyMacCore/ManifestStore.swift`: v2 schema, desired units, invalidation, work queues, materialization.
- `Sources/SearchMyMacCore/FlatVectorStore.swift`: reusable lane storage and compaction accounting.
- `Sources/SearchMyMacCore/SemanticVectorIndex.swift`: named passage/document indexes and generations.
- `Sources/SearchMyMacCore/LocalSearchEngine.swift`: staged workers, dual retrieval, semantic RRF, cancellation.
- `Sources/SearchMyMacCore/Models.swift`: v2 status, coverage, storage, and cursor contracts.
- `Sources/SearchMyMacCore/EngineProtocol.swift`: model-bundle and v2 status operations.
- `Sources/SearchMyMacApp/SettingsView.swift`: installation, storage, and coverage presentation.
- `Sources/SearchMyMacApp/ContentView.swift`: partial-coverage messaging and topic-match treatment.
- `Sources/SearchMyMacCLI/main.swift`: dual-lane read-only search and status errors.
- `Tests/SearchMyMacCoreTests/SearchMyMacCoreTests.swift`: schema, durability, retrieval, and relevance regressions.
- `docs/ARCHITECTURE.md`, `docs/RELEASE_GATES.md`, `README.md`, and `docs/CLI_REFERENCE.md`: final behavior after implementation.

## Explicit non-goals for this change

- Generative answers or document summarization in search results.
- Uploading documents, queries, or generated concepts.
- Replacing lexical search with embeddings.
- Embedding one entire unbounded document as a single vector.
- Preserving old semantic vector generations or migrating mixed-model vectors.
- Showing implementation details such as HNSW, SQLite, or raw cosine scores in the normal UI.
