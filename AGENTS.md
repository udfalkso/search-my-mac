# Search My Mac — Agent Handoff Guide

This file is the durable starting point for work in this repository. Read it before making changes when prior conversation context is unavailable.

## Product intent

Search My Mac is a native, local-first macOS app for substantially better document search than Finder. It progressively discovers and indexes user-selected roots, supports full-text and Qwen3-based semantic/hybrid queries with multiple snippets per result, filters, saved searches, deduplicated local history, keyboard navigation, Quick Look, and an Index Health view.

The main app remains resident after its windows close. It owns filesystem/TCC access, security-scoped bookmarks, FSEvents, scheduling, and UI. Explicit Quit stops the app. Do not move protected-folder access into a LaunchAgent.

## Repository layout

- `Sources/SearchMyMacApp/`: SwiftUI/AppKit app, state model, settings, global shortcut, and Quick Look.
- `Sources/SearchMyMacCLI/`: read-only `smm` CLI with JSON/JSONL/path/text output for automation and AI tools.
- `Sources/SearchMyMacCore/`: discovery, extraction, SQLite manifest/FTS, ranking, FSEvents, vectors, and XPC contracts.
- `Sources/SearchMyMacEngineService/`: bundled authenticated engine XPC service.
- `Tests/SearchMyMacCoreTests/`: Swift Testing coverage for indexing, queries, migrations, vectors, XPC, history, and discovery policy.
- `rust-engine/`: Tantivy Rust `cdylib` and C ABI. Tantivy is the active lexical path once its committed generation matches SQLite; FTS5 is the repair-time fallback.
- `Resources/`: app/XPC plists and development/distribution entitlements.
- `scripts/build-app.sh`: Swift/Rust build, `.app` assembly, and inside-out signing.
- `docs/ARCHITECTURE.md`: architecture and durability decisions.
- `docs/CLI_REFERENCE.md`: machine-oriented contract and safe usage guidance for the bundled `smm` command.
- `docs/RELEASE_GATES.md`: known work required before public release.

There is no Xcode project. The codebase is a Swift Package plus a Rust crate.

## Common commands

Run commands from the repository root.

```sh
# Build, assemble, and sign the runnable app bundle
./scripts/build-app.sh

# Build a .pkg that installs the app and /usr/local/bin/smm
./scripts/build-installer.sh

# Test Swift code using workspace-local caches
CLANG_MODULE_CACHE_PATH=.build/clang-cache swift test \
  --disable-sandbox \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security

# Test the Rust/Tantivy engine
cargo test --manifest-path rust-engine/Cargo.toml

# Verify the assembled signature
codesign --verify --deep --strict --verbose=2 ".build/Search My Mac.app"

# Launch the assembled app after quitting any older running copy
open ".build/Search My Mac.app"

# Inspect signing identities when packaging reports an unavailable identity
security find-identity -v -p codesigning

# Inspect repository state
git status --short --branch
git diff --check
```

Running `swift build` alone does not create the runnable application bundle. Use `scripts/build-app.sh` for user testing. Rebuilding replaces the bundle on disk but does not replace an already running process; quit Search My Mac and reopen it to test UI or behavior changes.

Some agent sandboxes cannot write Swift's normal caches or read the login keychain. Prefer the workspace-local cache flags above. If certificate signing is still unavailable, rerun the build with explicitly approved access rather than changing signing configuration.

## Local signing

The developer machine may have an ignored `.smm-signing.env` containing:

```text
SMM_CODESIGN_IDENTITY=<certificate SHA-1 fingerprint>
SMM_TEAM_ID=<Apple Developer Team ID>
```

Never commit `.smm-signing.env`, certificate material, passwords, or private keys. The file is intentionally in `.gitignore`. A stable Apple Development signature prevents macOS from treating every rebuild as a different app and repeatedly asking for Desktop/Documents/Downloads permission. Development builds use launch-safe entitlements; private marker entitlements are only enabled with `SMM_PRIVATE_ENTITLEMENTS=1` for a provisioned distribution build.

If `open` fails with `RBSRequestErrorDomain Code=5`, `NSPOSIXErrorDomain Code=163`, or “launchd job spawn failed,” first rebuild with the available stable signing identity and run the `codesign --verify` command above. Inspect Console only after signature/bundle verification succeeds.

## Important implementation invariants

### Development persistence policy

- This is a new application under active development. Do not preserve obsolete development index formats or add migration complexity merely to protect local test data.
- Prefer a clean schema/version reset and complete reindex when an architectural change makes that simpler or safer. The local index is disposable and rebuildable.
- Keep genuinely user-owned configuration conceptually separate from derived index data in the final architecture, even if development resets currently clear both.

### Discovery and indexing

- Discovery and extraction are pipelined. Bounded batches are staged in SQLite and relevant files begin indexing before the complete filesystem walk finishes.
- Pause must stop both discovery and extraction. Counts must not continue changing while paused.
- Background indexing is intentionally throttled when the app is not active.
- FSEvents is a hint, not a ledger. Dropped/wrapped events and directory changes require reconciliation.
- Do not infer deletions from an incomplete or inaccessible scan. External roots that are unavailable remain offline, not deleted.
- Policy-excluded records are safe to remove even during an otherwise incomplete reconciliation; this cleans records created under older policies.
- Increment `DiscoveryPolicy.version` whenever exclusion behavior changes. On the next reconciliation, each root incrementally purges records admitted by an older policy before starting filesystem discovery.
- Check file identity before and after extraction. Discard and requeue unstable results.
- Do not follow symlinks or recurse into packages, arbitrary archives, attachments, or app internals.
- Common standalone image formats are content-bearing files. Extract their visible text locally with Vision OCR using bounded, downsampled images; never upload image content.

`DiscoveryPolicy` applies high-confidence structural exclusions before traversal work is performed. It excludes common source-code extensions by default, along with dependency/build/cache trees including `node_modules`, the contiguous relative path `go/pkg/mod`, Python environments and `site-packages`, CocoaPods, Carthage, SwiftPM output, and DerivedData. Entire Home scans treat `~/Library` as a corridor only to `CloudStorage` and `Mobile Documents`. Selecting an otherwise excluded folder directly makes it the root and intentionally opts it back in; the source-code switch can be disabled when code itself should be indexed. Apply the same policy to full scans and single-file FSEvents handling so ignored content cannot re-enter the index.

macOS has no trustworthy “the user authored this file” attribute. Do not substitute owner UID, creation date, or quarantine metadata as provenance. Prefer conservative structural defaults plus future user-visible include/exclude controls.

### Search and persistence

- SQLite is authoritative for roots, files, passages, operations, history, saved searches, and event positions. Tantivy/HNSW are derived and must be rebuildable.
- Search results are grouped by source and can show up to three matching passages.
- Highlight ranges crossing into SwiftUI/AppKit are UTF-16 ranges, not UTF-8 offsets.
- Pagination cursors include the index generation and must fail cleanly when stale.
- Search history is normalized for case, accents, width, and whitespace. Repeating a query replaces/moves the existing entry rather than creating a duplicate.
- Semantic and Hybrid modes report the effective mode as text until at least one passage embedding is searchable. The optional model is Qwen3 Embedding 0.6B Q8 GGUF, loaded through llama.cpp; never remove its size/SHA-256 verification.
- Semantic indexing advances in coverage rounds across distinct source files. Within a round, newer files come first; CSV, TSV, Excel, ODS, and Numbers files are deliberately lowest priority so large tabular data cannot crowd out prose documents.

### Security and privacy

- No telemetry or document/query upload by default.
- XPC connections must authenticate the expected signing identity and bundle identifier on both sides and use strict secure class lists, size limits, timeouts, request IDs, and cancellation.
- The eventual extractor service should receive already-open read-only file handles, not broad home-directory access.
- Never execute macros, formulas, scripts, HTML resources, or embedded objects while extracting.
- Index storage is owner-only. FileVault protects data at rest but not from other software already executing as the logged-in user.
- Never claim Full Disk Access can be detected through a supported API. Report tested coverage and inaccessible locations.

## Current UX decisions

- The bottom indexing status uses concise text and an activity spinner; there is no determinate progress bar.
- Index Health is a separate utility row pinned at the bottom of the sidebar, visually separated from result-producing scopes.
- The file-type menu shows selected state and count.
- The semantic-pending notice links to Semantic settings.
- Result context menus use concrete icons; Space invokes Quick Look for the selected result.
- The Save Search bookmark has explanatory hover help.
- Search history must not contain normalized duplicates.

## Testing expectations

For core changes, run the complete Swift suite. Run Rust tests when changing the Rust engine, its ABI, Cargo dependencies, or integration assumptions. For packaging, entitlements, XPC, or signing changes, also assemble the app and verify it with `codesign --deep --strict`.
The app and engine executables dynamically link `llama.framework`. The packaging script must retain `@executable_path/../Frameworks` in both executables' `LC_RPATH`; code-signing verification alone does not detect a missing runtime library path.

Tests use temporary directories. macOS may present the same temporary path as `/var/...` or `/private/var/...`; compare canonical identity or stable suffixes rather than raw spelling when the alias is irrelevant.

Do not weaken a safety behavior merely to make a fixture pass. Add regression tests for migration and cleanup behavior whenever persistent index semantics change.

## Git practices

- Preserve unrelated user changes in a dirty worktree.
- Generated `.build/`, `rust-engine/target/`, and `.smm-signing.env` content must remain untracked.
- Use `apply_patch` for source edits.
- When asked to commit, write a descriptive subject and body covering all significant changes; do not omit material behavior from the message.
