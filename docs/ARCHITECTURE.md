# Architecture

## Process ownership

Interactive search has priority over background indexing. Focusing the search
field in the active app holds the gate until focus leaves or the app becomes
inactive. The app also signals typing before its debounce; a shared gate holds discovery, extraction, semantic workers,
and derived-index maintenance at safe checkpoints while queries are active and
for 500 ms afterward. Overlapping requests keep the gate held until all finish,
including cancellation and error paths. Cancelled semantic queries skip inference
once they acquire the model gate. Already-running synchronous work finishes its
current unit before yielding. Tantivy reset and commit run off the engine actor;
queries use authoritative SQLite FTS while those operations are in flight.
Each new search clears previous results and immediately presents a loading spinner.

Health and semantic-status reporting use a separate read-only SQLite connection
and actor so full-index counts cannot block search between its database stages.
Semantic status polls are coalesced, spaced at least five seconds apart, and
serve the in-memory state whenever search has priority, including the first poll.
Model loading initializes semantic readiness independently of periodic reporting.
This matters even in Text mode: coverage reporting previously scanned hundreds
of thousands of passages on the search actor's database several times per second.

The shared priority gate also parks periodic health/progress UI polling and
reconciliation, filesystem-event processing before database access, background
model loading/inference, vector writes and rebuilds, and extraction between PDF
pages and before OCR. Text-mode startup defers optional model loading until idle;
loading required for a selected semantic mode remains foreground preparation.
Waiting background tasks remain cancellable, and releasing search priority does
not release an explicit indexing pause. A running synchronous parser call,
database transaction, native index operation, or GPU decode cannot be suspended
mid-operation; it completes its current unit before the next checkpoint. Search
execution, its result rendering/preview, and explicitly requested settings work
remain foreground operations. Filesystem notifications are retained for later
processing rather than discarded while searching.

For local search profiling, launch the assembled app with
`open --env SMM_PROFILE_SEARCH=1 ".build/Search My Mac.app"` after quitting the
running copy. Inspect the `com.searchmymac.app` / `SearchPerformance` category in
Console. Timings include UI scheduling, generation reads, Tantivy lookup, history,
materialization, engine completion, and assignment of results to the UI. Each
trace's elapsed time starts at its own entry point; correlate stages by request
UUID. Logs contain timings and request IDs, never queries or document content.

Semantic passage vectors are precomputed during indexing. An immutable HNSW
snapshot covers the published vectors; newer vectors remain searchable through
an exact delta search. The delta search caches checksum-validated Float32 values
and norms (up to 64 MiB of vector payload), uses Accelerate for cosine scoring,
and caches delta membership by snapshot generation and vector-store revision.
Replacing/tombstoning vectors and publishing snapshots invalidate the relevant
cache entries. Model preparation warms the HNSW view and delta cache before
marking semantic search ready. This avoids rereading, rehashing, and decoding
thousands of vectors for every keystroke without changing the exact-delta ranking
method or requiring a reindex.

The opt-in `profileLiveSemanticSearch` test opens the local index read-only and
reports model loading, index opening, query embedding, vector search, and result
materialization times. Enable it with `SMM_PROFILE_SEMANTIC=1`; optionally set
`SMM_PROFILE_PREWARM=1` and `SMM_PROFILE_QUERY`. It requires local GPU access and is
skipped by the ordinary test suite. Profile logs contain only timings and counts.

The resident main application owns root selection, protected-folder access, file discovery, FSEvents, scheduling, progress, and presentation. Closing all windows does not terminate it; explicit Quit does.

The bundled engine XPC service is app-sandboxed and exports only a small data protocol. Its listener rejects connections unless the caller satisfies its configured code-signing requirement, and the client applies the corresponding service requirement before resuming its connection. Provisioned release builds pin identifiers, Team ID, and private entitlements. Ad-hoc development signatures cannot legally carry those custom restricted entitlements on current macOS, so development builds use identifier-only requirements and are not a security-equivalent distribution artifact.

The current development data path remains in-process, but lexical queries use the bundled Tantivy engine whenever its commit payload matches SQLite's authoritative generation. SQLite records the latest pending operation per source; crashes before or after a Tantivy commit are repaired idempotently from that journal, and FTS5 remains available during initial rebuild or repair. The XPC bundle is assembled now so signing, sandboxing, and ABI failures are caught early; moving this completed data path behind authenticated XPC remains a release gate.

Document extraction prefers a separate bytes-only Rust adapter built on pinned
`anydoc` and `pdf-inspector` releases. The adapter receives no paths and returns
bounded plain text or page-aware PDF text plus OCR-routing hints. Office,
OpenDocument, RTF, and EPUB containers use the structured adapter, with system
readers retained as compatibility fallbacks. PDFs use its layout-aware text for
pages that pass encoding and content-quality checks; PDFKit and local Vision OCR
remain the fallback for flagged, vector-text, image-heavy, or scanned pages.
Pages, Numbers, and Keynote continue through the system metadata importer. The
resident app still performs this work in-process during development; moving the
same byte interface into the planned file-handle-only extractor XPC boundary is
a release gate.

The signed app also bundles the `smm` command-line client. The installer exposes it
at `/usr/local/bin/smm` with a symlink back into the application bundle, so the CLI
and app cannot drift onto different engine versions. CLI sessions open SQLite and
the vector generations read-only, do not start discovery or indexing workers, and
never record search history. They do not grant a caller additional filesystem or
TCC access: a process invoking `smm` can only read the index with the permissions it
already has as the logged-in user. Semantic CLI queries use CPU inference because
automation sandboxes do not consistently permit Metal command queues.

## Durable state

SQLite is authoritative. It stores roots, file identity and availability, extraction recipe versions, desired/applied generations, passages, history, saved searches, staged discovery manifests, and FSEvents positions. FTS and vectors are derived and replaceable.

Initial discovery writes prioritized bounded batches to `scan_items`, while a consumer immediately extracts and indexes unprocessed staged rows. The discovery-phase progress bar measures the share of files found so far that have already been indexed; because the denominator is still growing, it is explicitly labeled “live.” Once enumeration completes, the denominator freezes and the percentage becomes exact. Deletion reconciliation still happens only after a successful complete scan of an available root. A cancelled or failed scan discards its staging generation and does not infer deletion.

Each file records the extraction recipe version that last attempted it. A parser
change increments only the affected extensions. On the first launch after an
upgrade, stale recipes make startup reconciliation immediately due; discovery
still skips every unchanged file whose recipe is current. Successful legacy
content and legacy failures are both retried once because either may benefit
from a new parser. The new version is recorded even when the new attempt fails,
so automatic migration cannot become an infinite retry loop; failures remain
available through the explicit retry control.

The semantic pipeline uses the official Qwen3 Embedding 0.6B Q8 GGUF through a pinned universal llama.cpp framework. The app validates the optional model download by exact size and SHA-256 before loading it. Documents are embedded without an instruction; queries use Qwen's retrieval instruction format. Both outputs are normalized 1024-dimensional vectors.

The vector store appends canonical float16 payloads and journals offsets, SHA-256 checksums, and tombstones. Published USearch HNSW generations are immutable, memory-mapped, and int8-quantized. Queries merge approximate snapshot results with exact results from the durable delta; publication uses a temporary file, count validation, and atomic manifest replacement. SQLite records passage/model completion and deletion tombstones, so interrupted work is replayable.

Semantic work selection groups completed counts once per source and joins that
summary to pending passages. It must not use a per-passage correlated count over
the growing embedded set: that shape becomes progressively slower and can make a
healthy worker appear stalled after several thousand embeddings. Newer files are
preferred while work is distributed across sources, with spreadsheet and CSV
content intentionally assigned the lowest priority.

## Search

Text-bearing files become passage documents; filename-only files receive an empty metadata passage so they remain searchable. The baseline lexical weights are filename 5.0, title 3.0, body 1.0, and path 0.7. Search retrieves a larger passage candidate set, groups by source, retains the best three snippets, and applies decreasing secondary-passage weights.

Pagination cursors carry the manifest generation and fail cleanly when stale. Highlight offsets are generated with `NSString`, so values crossing the process/UI boundary are UTF-16 ranges suitable for AppKit even around emoji and composed characters.

## Filesystem recovery

FSEvents is treated as a hint. `MustScanSubDirs`, user/kernel drops, event-ID wrapping, and root changes trigger reconciliation. A normal file event re-extracts only that source after before/after identity checks. Directory events trigger a scoped-via-root reconciliation in v0.1. Existing roots reconcile at launch when due or when an extraction recipe changed, daily, and after wake; unchanged sources with current recipes skip extraction.

External roots that cannot be reached are marked offline. Their records are retained. Records are removed only after an available root is fully reconciled or the user removes that root.

## Storage and privacy

Index storage is created with mode `0700`; vector data uses `0600`. Indexing pauses before available capacity falls below the greater of 5 GB or 5% of the volume. No network or telemetry code is present. FileVault protects data at rest, but does not isolate the index from other software already executing as the logged-in user.
