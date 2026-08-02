# Architecture

## Process ownership

The resident main application owns root selection, protected-folder access, file discovery, FSEvents, scheduling, progress, and presentation. Closing all windows does not terminate it; explicit Quit does.

The bundled engine XPC service is app-sandboxed and exports only a small data protocol. Its listener rejects connections unless the caller satisfies its configured code-signing requirement, and the client applies the corresponding service requirement before resuming its connection. Provisioned release builds pin identifiers, Team ID, and private entitlements. Ad-hoc development signatures cannot legally carry those custom restricted entitlements on current macOS, so development builds use identifier-only requirements and are not a security-equivalent distribution artifact.

The current development data path remains in-process until journal replay between SQLite and Tantivy is completed. The XPC bundle and Rust library are assembled now so signing, sandboxing, and ABI failures are caught early.

## Durable state

SQLite is authoritative. It stores roots, file identity and availability, desired/applied generations, passages, history, saved searches, staged discovery manifests, and FSEvents positions. FTS and vectors are derived and replaceable.

Initial discovery writes prioritized bounded batches to `scan_items`, while a consumer immediately extracts and indexes unprocessed staged rows. The discovery-phase progress bar measures the share of files found so far that have already been indexed; because the denominator is still growing, it is explicitly labeled “live.” Once enumeration completes, the denominator freezes and the percentage becomes exact. Deletion reconciliation still happens only after a successful complete scan of an available root. A cancelled or failed scan discards its staging generation and does not infer deletion.

The vector store appends canonical float16 payloads and records offsets and SHA-256 checksums in an atomically replaced manifest. Published HNSW generations will remain immutable. Queries will merge that generation with exact results from the durable delta; publication uses temporary files, validation, and atomic rename.

## Search

Text-bearing files become passage documents; filename-only files receive an empty metadata passage so they remain searchable. The baseline lexical weights are filename 5.0, title 3.0, body 1.0, and path 0.7. Search retrieves a larger passage candidate set, groups by source, retains the best three snippets, and applies decreasing secondary-passage weights.

Pagination cursors carry the manifest generation and fail cleanly when stale. Highlight offsets are generated with `NSString`, so values crossing the process/UI boundary are UTF-16 ranges suitable for AppKit even around emoji and composed characters.

## Filesystem recovery

FSEvents is treated as a hint. `MustScanSubDirs`, user/kernel drops, event-ID wrapping, and root changes trigger reconciliation. A normal file event re-extracts only that source after before/after identity checks. Directory events trigger a scoped-via-root reconciliation in v0.1. Existing roots reconcile at launch, daily, and after wake; unchanged sources skip extraction.

External roots that cannot be reached are marked offline. Their records are retained. Records are removed only after an available root is fully reconciled or the user removes that root.

## Storage and privacy

Index storage is created with mode `0700`; vector data uses `0600`. Indexing pauses before available capacity falls below the greater of 5 GB or 5% of the volume. No network or telemetry code is present. FileVault protects data at rest, but does not isolate the index from other software already executing as the logged-in user.
