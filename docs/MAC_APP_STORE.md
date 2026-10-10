# Mac App Store submission preparation

## Account and current status

Use only Udi Falkson's personal provider, displayed as **Udi F** in App Store Connect. Do not use CycleLytic, ESPN, Purpose Campaigns, Soundprint, or Yoni Falkson. The personal provider was verified in Arc on October 10, 2026. No app has been submitted for review.

The repository now supports a separate App Store build via `SMM_APP_STORE=1`. It omits Sparkle from the app dependency graph and bundle, removes external-update settings and menu commands, omits the bundled CLI, uses read-only user-selected folder access with persistent security-scoped bookmarks, and opens Word results normally without AppleScript automation. Developer ID builds retain their existing behavior.

App Store Connect app ID: `6821426922`; bundle resource ID: `QQ2L5N7R75`; personal Developer Team ID: `K5FGQ428RU`. The draft version has been aligned to source version `0.2.6` (8), with copyright `2026 Udi Falkson`, Productivity/Utilities categories, and manual release.

Application certificate: `H8P4H2XVLS`, SHA-1 `60543E3704F93CA2DEDB1128BC85D19E9300F013`. Installer certificate: `KNBCPRRB87`, SHA-1 `260DB59D6C19A1EEAFCA8C6B0782F252EB10C397`. Both private keys were installed in the login keychain. Provisioning profile: `ZB6ZHM446A`, expires October 10, 2027. The signed package was assembled and its app and package signatures verified.

Corrected package upload `d64c1d81-12e2-4a15-b43e-70b681980137` was committed and is PROCESSING. It has not yet exposed a build ID. Check `asc builds uploads view --id ...` and `asc builds list --app 6821426922 --version 0.2.6 --build-number 8` before attaching it. Latest API readiness has two blocking checks: no attached build and no screenshots; IAPs still report missing review metadata. App Privacy and agreements remain unverified. No personal CLI web session is cached, and browser use is disabled by user request.

Repository-local asc authentication is ignored by git. Run `ASC_BYPASS_KEYCHAIN=1 asc --profile 'Udi Falkson Personal' ...` to avoid selecting an unrelated system-keychain default. Do not print private key contents. Arc use was stopped at the user's request.

## Build and signing

Run `bash scripts/build-app-store.sh` after supplying:

- `SMM_CODESIGN_IDENTITY`: personal team's Apple Distribution / Mac App Distribution application certificate identity.
- `SMM_TEAM_ID`: personal team's actual Developer Team ID (not the App Store Connect provider UUID).
- `SMM_APP_STORE_PROFILE`: Mac App Store provisioning profile for `com.searchmymac.app` and that certificate.
- `SMM_INSTALLER_IDENTITY`: personal team's Mac Installer Distribution identity.

Output: `.build/app-store/Search My Mac.app` and `.build/app-store/Search My Mac.pkg`. This uses `productbuild --component`, without a `/usr/local/bin` installation. Do not submit the Developer ID installer. Do not notarize this App Store package as a substitute for App Store validation.

The sandbox has outbound network access for the optional, verified embedding-model download. Documents and queries remain local. No custom marker entitlements are used; mutual XPC authentication retains team and bundle identifier checks.

## Purchases and trial

The approved business model is a free App Store download, a seven-day free trial, and a US $9.99 non-consumable full unlock. No subscription or automatic charge follows the trial.

- Full unlock product: `com.searchmymac.app.fullunlock`, ASC ID `6821429239`.
- Free trial product: `com.searchmymac.app.trial7day`, ASC ID `6821429082`, localized as `7-day Trial`.
- StoreKit 2 verifies entitlements locally, derives trial expiry from the original purchase date, supports restoration, and monitors transaction updates and expiry. Only verified, non-revoked purchases grant access.
- The app model starts only after access is granted. On expiry or revocation it shuts down search/indexing workers and preserves the index. Closing windows retains the model while access remains active.
- Regression tests cover the seven-day boundary, restored trial dates, future trial dates, permanent unlock priority, revocation, and unrelated products. Both build configurations passed all 76 Swift tests.
- Verify the complete purchase UI, pending/cancelled/unverified outcomes, restore, refund, offline use, and accelerated trial expiry using Apple sandbox/TestFlight before submission. Unit tests and signature verification do not establish successful StoreKit purchases.

The support and privacy documents are published at the public GitHub URLs for `docs/SUPPORT.md` and `docs/PRIVACY.md`. Both URLs and the approved English listing are saved in App Store Connect. The full unlock description is **Unlock all features. One-time purchase.** Review contact is Udi Falkson, `udi@breasy.com`, `+16462853222`; no demo sign-in is required. Age-rating answers declare no supplied objectionable content or social features. Draft app and purchase availability includes all Apple territories and future territories.

## Remaining validation gates

- Validate and upload the signed package with Apple's tooling; both executable framework rpaths are retained by the build script.
- Test a clean sandbox container: folder selection, bookmark restoration after restart, full-text indexing, FSEvents, pause, external/offline volumes, Quick Look, ordinary document opening, model download, semantic search, and login launch.
- Test Pages/Numbers/Keynote compatibility extraction. The current `/usr/bin/mdimport` child process may not receive dynamically granted folder access in a sandbox; do not claim those formats work until verified or replaced with bytes-only extraction.
- Verify Rust libraries, llama.framework, USearch, and Metal inference under distribution sandbox signing. Compilation alone does not establish runtime compatibility.
- Verify download compliance for the optional model (data-only weights) and third-party licenses.
- Current source version is 0.2.6 (8). Use a new build number for subsequent uploads.
- First-party privacy manifests cover selected-file/container metadata, internal timing, low-space checks, and app-only defaults. Complete the third-party dependency privacy audit.
- Complete screenshots, published App Privacy answers, purchase-review screenshots, and paid-agreement verification.
- Upgraded asc from 0.31.2 to 5.14.1 to fix obsolete age-rating queries and the macOS package upload content type. Apple's first real processing attempt rejected an owner-only embedded provisioning profile (90255); the packaging script now sets that public bundled profile to mode 644 while keeping private signing material restricted.
- Run the broader release gates in `docs/RELEASE_GATES.md` applicable to the first public release.

## Draft English listing

Name: Search My Mac

Subtitle: Search inside your documents

Category: Productivity

Keywords: document,search,files,pdf,preview,text,local,finder,notes,offline

Description:

Find the words you need inside your documents—even when you do not remember the filename.

Search My Mac searches inside documents in the folders you choose. See matching passages in context and preview files with Quick Look before opening them. Narrow results with filters, save useful searches, and return to recent searches from your local history.

Text search is ready without downloading an AI model. Document indexing and search run locally; documents and search queries are not uploaded.

Indexing runs progressively, so you can start searching while more files are being indexed. Pause when needed and use Index Health to inspect coverage and extraction issues.

For searches where you remember an idea rather than the exact words, an optional semantic model adds search by meaning. You can enable it in Settings and choose Semantic or Hybrid mode. Text is the default search mode.

Try all features free for seven days. The trial does not charge you automatically. When it ends, unlock the app with a one-time purchase for US $9.99 (or the price shown in your local currency). There is no subscription. Your documents and local index are preserved when the trial ends.

Review notes draft:

Start the free `7-day Trial` purchase, or purchase `Full App Unlock`, to access search. Restore Purchases is available in the app menu and trial/purchase screen. The trial duration is calculated from the verified transaction's original purchase date; it does not restart on restoration. After expiry, indexing and searching stop without deleting documents or the local index. The app searches only folders selected through the macOS folder picker and retains read-only security-scoped bookmarks. Add a folder containing local PDF, text, and Word documents, wait for initial indexing, then enter a phrase from a document. Space previews a selected result. Semantic search is optional and requires a verified model download from Semantic settings. No developer account or sign-in is required; Apple handles purchases. The app remains running after its window closes to continue indexing; Quit stops it. This App Store build uses App Store updates and does not install a command-line tool or automate Microsoft Word.

## Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.4.5.
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [Create an App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)
