# Search My Mac

Search My Mac is a native macOS document-search application. It remains resident after its last window closes, incrementally indexes user-selected locations, and returns grouped full-text results with multiple highlighted passages.

This repository contains a runnable v0.1 engineering foundation for the revised architecture plan. It is intentionally local-first: no telemetry, query upload, or document upload exists.

## What works

- Native SwiftUI/AppKit application with onboarding, location and type filters, text/semantic/hybrid mode controls, history, saved searches, keyboard navigation, Quick Look-style open/reveal actions, indexing progress, and Index Health.
- Resident main-app lifecycle, optional login launch through `SMAppService.mainApp`, and a Command-Option-Space global shortcut.
- Durable SQLite manifest and journal state with WAL, owner-only storage, FTS5 lexical fallback, generation-bound cursors, BM25 field weights, UTF-16 highlight ranges, and up to three passages per source result.
- Pipelined, bounded discovery that stages prioritized 256-file batches in SQLite instead of retaining an entire million-file manifest in memory. Recent supported documents begin indexing while the filesystem walk is still running. During discovery the UI shows a live `indexed / found so far` backlog measure; after discovery it switches to an exact frozen percentage.
- Change detection using per-file FSEvents. Dropped events, wrapped IDs, changed roots, and `MustScanSubDirs` force reconciliation. Unchanged files are not re-extracted; unavailable roots are marked offline rather than deleted.
- PDFKit extraction by page, conservative scanned-page and standalone-image OCR with Vision, Foundation document readers, plain text/source/config ingestion, and system metadata-importer compatibility for iWork, spreadsheet, presentation, and EPUB containers while native structured adapters are completed.
- Before/after size and modification checks, extraction size limits, cancellation, parser timeouts, placeholder states, low-disk pauses, package skipping, symlink avoidance, and hard-link identity deduplication.
- High-confidence user-content discovery defaults prune source-code files plus dependency and generated trees such as `node_modules`, Go's module cache, Python environments, CocoaPods, Carthage, SwiftPM output, and Xcode DerivedData. Entire Home scans avoid managed `~/Library` content except iCloud Drive and cloud-provider document roots; explicitly choosing an excluded folder opts that root back in.
- An active Rust `cdylib` using Tantivy 0.26 with versioned field boosts, source grouping, coverage/proximity reranking, three-passage scoring, generation commits, C ABI ownership rules, and integration tests.
- A sandboxed engine XPC bundle with mutual code-signing requirements, exact protocol types, explicit secure class lists, request size limits, and client timeouts. Provisioned release builds additionally pin Team ID and private client/service entitlements; ad-hoc builds use identifier-only development requirements so AMFI will permit them to launch.
- Optional, fully local Qwen3 Embedding 0.6B inference through llama.cpp. The app verifies the 639 MB Q8 model by size and SHA-256, progressively embeds newest passages first, resumes after relaunch, and provides install/pause/resume/remove controls.
- An append-only float16 vector store with checksums and tombstones, exact delta search, and immutable memory-mapped int8 USearch HNSW generations published after validation at the 10,000-vector/5% delta threshold.
- Semantic retrieval honors folder, type, and date filters. Hybrid mode uses adjustable weighted reciprocal-rank fusion (65% text and 35% semantic by default), preserves filename/exact-text priority, and groups the best three passages per file.

## Build and test

Requirements: macOS 13.3 or newer, Xcode command-line tools, Swift 6, and Rust/Cargo.

```sh
CLANG_MODULE_CACHE_PATH=.build/clang-cache swift test \
  --disable-sandbox \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security

cargo test --manifest-path rust-engine/Cargo.toml
```

Assemble an ad-hoc signed development app:

```sh
./scripts/build-app.sh
open ".build/Search My Mac.app"
```

Build an installer package that places the app in `/Applications` and the
`smm` command in `/usr/local/bin`:

```sh
./scripts/build-installer.sh
```

Set `SMM_INSTALLER_IDENTITY` to sign this development/testing package with a
Developer ID Installer identity. Without it, the script creates an unsigned
package. Use the public release workflow below for distribution to other Macs.

Build the public installer with Developer ID Application and Installer
signatures, Apple notarization, a stapled offline ticket, and Gatekeeper
validation:

```sh
./scripts/notarize-installer.sh
```

The public workflow requires both Developer ID certificate types and either an
authenticated `asc` profile or `SMM_NOTARY_PROFILE` for `notarytool`. It writes
the final versioned package to `.build/distribution/`.

For stable Apple Development or Developer ID signing, set `SMM_CODESIGN_IDENTITY` and `SMM_TEAM_ID`, or place them in a local `.smm-signing.env` file. The local file is ignored by git. Prefer the certificate's SHA-1 fingerprint when duplicate certificate names exist. Signed development builds use Team-ID-and-bundle-ID-pinned mutual XPC requirements while retaining launch-safe development entitlements. Set `SMM_PRIVATE_ENTITLEMENTS=1` only for a provisioned distribution build that authorizes the private client/service marker entitlements. Ad-hoc builds use identifier-only development requirements; because their designated requirement is a changing code hash, macOS privacy permissions may be requested again after each rebuild.

## Command-line search

The installer adds `smm`, a read-only command-line client intended for shell
automation and local AI tools. It never records CLI searches in app history and
emits structured JSON by default.

For the complete machine-oriented output contract and safe AI usage guidance,
see [the CLI reference](docs/CLI_REFERENCE.md).

```sh
smm "quarterly revenue"
smm "Maryland license" --mode hybrid --type pdf --limit 5
smm "project launch notes" --path ~/Documents --jsonl
```

Useful options include `--mode text|semantic|hybrid`, repeatable `--path` and
`--type` filters, `--after`/`--before` dates, `--semantic-weight`, and
`--format json|jsonl|paths|text`. Semantic and Hybrid modes use the local model
installed by Search My Mac. The CLI uses CPU inference so it remains usable in
automation sandboxes that do not permit Metal access.

## Repository layout

- `Sources/SearchMyMacApp`: resident app lifecycle and SwiftUI/AppKit interface.
- `Sources/SearchMyMacCLI`: read-only `smm` command for automation and AI tools.
- `Sources/SearchMyMacCore`: manifest, discovery, extraction, monitoring, search contracts, XPC client, and vector durability.
- `Sources/SearchMyMacEngineService`: authenticated private engine XPC listener.
- `rust-engine`: Tantivy engine and C ABI.
- `Resources`: bundle metadata and signing entitlements.
- `scripts/build-app.sh`: Swift/Rust build, bundle assembly, and inside-out code signing.
- `scripts/build-installer.sh`: package assembly for the app and `/usr/local/bin/smm`.
- `docs/ARCHITECTURE.md`: ownership, durability, security boundaries, and recovery rules.
- `docs/RELEASE_GATES.md`: work that must pass before a public release.

## Important current limits

The checked-in application is a solid vertical slice, not yet a public-release build. Tantivy is the active in-process lexical backend whenever its durable generation matches SQLite; SQLite FTS5 keeps search available while Tantivy is initially built or repaired. The authenticated XPC path is built and tested independently but still needs to become the production process boundary. Native OOXML/Calamine adapters, file-handle-only extractor XPC service, provider-specific cloud tests, judged relevance tuning, and the full million-record performance corpus remain release-gate work.

Semantic search is opt-in because it downloads a local model and can require substantial indexing time. Until at least one passage has an embedding, Semantic and Hybrid searches explicitly fall back to text results. Modern iWork uses the system importer; unsupported revisions remain filename-searchable.
