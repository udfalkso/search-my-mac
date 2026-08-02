# Release gates

The following items are deliberately tracked as release blockers rather than being hidden behind UI polish.

## Engine integration

- Route production lexical writes/searches through the authenticated engine XPC service and Tantivy library.
- Complete the SQLite operation journal: desired generation, Tantivy commit metadata, applied generation, crash injection at every boundary, and idempotent replay.
- Add delete/reconfigure/index-management messages with the same authentication, payload, timeout, request-ID, and cancellation controls.
- Stress-test the one-shot XPC reply gate under interruption/error/timeout races.

## Extraction isolation and coverage

- Add a separate sandboxed extractor XPC service that accepts only already-open read-only file handles and bounded metadata.
- Add direct OOXML parsers for DOCX/PPTX and Calamine-backed XLS/XLSX/XLSB/ODS extraction; retain Foundation/system-importer fallback only where documented.
- Add archive entry, expanded byte, compression ratio, recursion, pixel/page, text-retention, and per-parser wall-clock limits to every container adapter.
- Verify HTML parsing cannot fetch remote resources or execute scripts.
- Test `mdimport -t` property-list variants across the supported Pages/Numbers/Keynote fixture matrix.
- Move compatibility importer temporary data into an owner-only directory and apply executable launch constraints.

## Semantic search

- Validate the pinned Qwen3 Embedding 0.6B Q8 llama.cpp runtime and tokenizer against the official reference implementation on every supported Apple-silicon and Intel baseline.
- Verify output parity on supported Apple silicon and Intel references.
- Stress immutable, memory-mapped USearch generation publication, low-disk failure, corruption handling, and rollback under forced termination.
- Quantize only if int8 recall@10 is within 2% of float16 on the judged corpus.
- Implement weighted RRF over the top 200 candidates and lexical-priority rules for identifiers, filenames, rare proper nouns, and quoted phrases.
- Tune progressive semantic scheduling and add a calibrated ETA after collecting representative per-machine throughput data.

## Platform risk spike

- Clean installations of macOS 13, 14, 15, and 26: TCC coverage, Desktop/Documents/Downloads, Full Disk Access, login launch, explicit Quit, and external volumes.
- Unauthorized, differently signed XPC client rejection and authorized-client acceptance with production signing.
- Metadata-only cloud-placeholder inspection for iCloud Drive, Dropbox, and OneDrive with network observation proving no unrequested download.
- Corrupt/huge PDFKit and Foundation worker fixtures, password-protected documents, archive bombs, and parser timeout/cancellation.
- Sleep/wake, dropped FSEvents, event-ID wrap simulation, renamed roots, offline volumes, hard links, copies, and reconciliation after long downtime.

## Performance and relevance

- Generate the target corpus: 1,000,000 metadata records, 50,000 content documents, and about 500,000 passages with realistic churn and failures.
- Meet warm lexical p95 under 100 ms on baseline Apple silicon and 200 ms on Intel; hybrid under 250/500 ms.
- Keep main-thread indexing/rebuild work under 50 ms and validate memory, thermal, battery, and index-size behavior.
- Build a versioned, human-judged relevance corpus; meet the NDCG/recall regression thresholds before changing ranking constants.
- Exercise low-space rebuilds near the 5 GB/5% threshold and prove no partial generation can be published.

## Distribution

- Produce universal or separately distributed Apple-silicon/Intel builds.
- Add app icon, accessibility audit, VoiceOver labels, localization readiness, update signing, notarization, and a privacy disclosure.
- Run `codesign --verify --deep --strict`, notarization, stapling, and Gatekeeper validation on every release artifact.
