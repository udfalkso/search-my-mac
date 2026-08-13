# Publishing a release

Search My Mac releases are built, signed, notarized, and appcast-signed on the
developer Mac. GitHub hosts the finished artifacts but does not build them.

## One-time setup

1. Install and authenticate GitHub CLI:

   ```sh
   brew install gh
   gh auth login
   ```

2. Install the Developer ID Application certificate and configure Apple
   notarization as described in the README. The local `.smm-signing.env` must
   include `SMM_TEAM_ID`; signing identities and notarization credentials must
   remain outside the repository.

3. Preserve the Sparkle Ed25519 private key stored in the login Keychain. The
   corresponding public key committed in `Resources/App/Info.plist` is:

   ```text
   F4w1IxR4Il2Ld/j2gwDciFNsd5GeKF43ijqV20kYoHk=
   ```

   Sparkle's `generate_keys --account com.searchmymac.app` command can inspect
   or export a backup. Do not commit the private key or its export password. All
   future releases must use this account and key unless a deliberate Sparkle
   key-rotation procedure is completed first.

   On the first publication, macOS may ask whether `generate_appcast` can read
   the Keychain item. Choose **Always Allow** so later local releases can be
   signed without another prompt.

## Release steps

1. Set both the user-visible version and monotonically increasing build number:

   ```sh
   ./scripts/set-version.sh 0.2.0 2
   ```

2. Review and commit the two Info.plist changes, along with the release's code.
   Push that commit to GitHub. The publisher intentionally refuses to release a
   dirty tracked worktree.

3. Supply short Markdown release notes directly, then publish from the committed
   checkout:

   ```sh
   ./scripts/publish-release.sh --notes "Add signed, automatic in-app updates."
   ```

   For longer notes, read Markdown from a file instead:

   ```sh
   ./scripts/publish-release.sh --notes-file /path/to/release-notes.md
   ```

   Add `--draft` to upload a private draft for inspection. Publishing the draft
   in GitHub makes it the live update feed.

The publisher runs `scripts/notarize-app.sh`, verifies the archive, uses
Sparkle's pinned `generate_appcast` tool and the private Keychain key to sign the
archive and feed, then creates `v<version>` with these assets:

- `Search My Mac-<version>.zip`: Developer ID-signed, notarized, and stapled app
- `appcast.xml`: signed Sparkle feed pointing to that tag's immutable ZIP asset

Installed apps check the stable URL below. GitHub redirects it to the appcast
asset on the latest published, non-prerelease release:

```text
https://github.com/udfalkso/search-my-mac/releases/latest/download/appcast.xml
```

Do not edit either asset after publication. Make corrections in a new version
with a higher build number so Sparkle's signature and version guarantees remain
intact.

## Smoke test

Before announcing a release, install the preceding public version in
`/Applications`, publish the new release, choose **Check for Updates…**, and
verify download, signature validation, replacement, relaunch, and the displayed
version. Also test one scheduled background check before the first public
rollout.
