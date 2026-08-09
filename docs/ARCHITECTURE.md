# Architecture

## Process ownership

The resident main application owns root selection, protected-folder access, file discovery, FSEvents, scheduling, progress, and presentation. Closing all windows does not terminate it; explicit Quit does.

The bundled engine XPC service is app-sandboxed and exports only a small data protocol. Its listener rejects connections unless the caller satisfies its configured code-signing requirement, and the client applies the corresponding service requirement before resuming its connection. Provisioned release builds pin identifiers, Team ID, and private entitlements. Ad-hoc development signatures cannot legally carry those custom restricted entitlements on current macOS, so development builds use identifier-only requirements and are not a security-equivalent distribution artifact.

The current development data path remains in-process, but lexical queries use the bundled Tantivy engine whenever its commit payload matches SQLite's authoritative generation. SQLite records the latest pending operation per source; crashes before or after a Tantivy commit are repaired idempotently from that journal, and FTS5 remains available during initial rebuild or repair. The XPC bundle is assembled now so signing, sandboxing, and ABI failures are caught early; moving this completed data path behind authenticated XPC remains a release gate.

The signed app also bundles the `smm` command-line client. The installer exposes it
at `/usr/local/bin/smm` with a symlink back into the application bundle, so the CLI
and app cannot drift onto different engine versions. CLI sessions open SQLite and
the vector generations read-only, do not start discovery or indexing workers, and
never record search history. They do not grant a caller additional filesystem or
TCC access: a process invoking `smm` can only read the index with the permissions it
already has as the logged-in user. Semantic CLI queries use CPU inference because
automation sandboxes do not consistently permit Metal command queues.

## Durable state

SQLite is authoritative. It stores roots, file identity and availability, desired/applied generations, passages, history, saved searches, staged discovery manifests, and FSEvents positions. FTS and vectors are derived and replaceable.

Initial discovery writes prioritized bounded batches to `scan_items`, while a consumer immediately extracts and indexes unprocessed staged rows. The discovery-phase progress bar measures the share of files found so far that have already been indexed; because the denominator is still growing, it is explicitly labeled “live.” Once enumeration completes, the denominator freezes and the percentage becomes exact. Deletion reconciliation still happens only after a successful complete scan of an available root. A cancelled or failed scan discards its staging generation and does not infer deletion.

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

FSEvents is treated as a hint. `MustScanSubDirs`, user/kernel drops, event-ID wrapping, and root changes trigger reconciliation. A normal file event re-extracts only that source after before/after identity checks. Directory events trigger a scoped-via-root reconciliation in v0.1. Existing roots reconcile at launch, daily, and after wake; unchanged sources skip extraction.

External roots that cannot be reached are marked offline. Their records are retained. Records are removed only after an available root is fully reconciled or the user removes that root.

## Storage and privacy

Index storage is created with mode `0700`; vector data uses `0600`. Indexing pauses before available capacity falls below the greater of 5 GB or 5% of the volume. No network or telemetry code is present. FileVault protects data at rest, but does not isolate the index from other software already executing as the logged-in user.
