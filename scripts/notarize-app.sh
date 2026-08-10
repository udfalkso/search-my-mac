#!/usr/bin/env bash
set -euo pipefail

# Builds a Developer-ID-signed, notarized ZIP without touching the normal
# development app bundle. Signing identities stay in the ignored local config;
# notarization credentials stay in the developer's Keychain or asc profile.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="${SMM_DISTRIBUTION_OUTPUT_DIR:-$PROJECT_ROOT/.build/distribution}"
APP_PATH="$OUTPUT_ROOT/Search My Mac.app"
ARCHIVE_PATH="$OUTPUT_ROOT/Search My Mac-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Resources/App/Info.plist").zip"
NOTARY_ARCHIVE_PATH="$OUTPUT_ROOT/Search My Mac-notarization.zip"

if [[ -n "${SMM_DISTRIBUTION_SIGNING_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="$SMM_DISTRIBUTION_SIGNING_IDENTITY"
else
  mapfile -t DEVELOPER_ID_IDENTITIES < <(
    security find-identity -v -p codesigning \
      | awk '/Developer ID Application/ { print $2 }'
  )
  case "${#DEVELOPER_ID_IDENTITIES[@]}" in
    1) SIGNING_IDENTITY="${DEVELOPER_ID_IDENTITIES[0]}" ;;
    0)
      echo "No Developer ID Application certificate is installed." >&2
      echo "Create one in Xcode or the Apple Developer portal, then rerun this script." >&2
      exit 1
      ;;
    *)
      echo "More than one Developer ID Application certificate is installed." >&2
      echo "Set SMM_DISTRIBUTION_SIGNING_IDENTITY to the certificate SHA-1 fingerprint to choose one." >&2
      exit 1
      ;;
  esac
fi

mkdir -p "$OUTPUT_ROOT"
rm -f "$ARCHIVE_PATH" "$NOTARY_ARCHIVE_PATH"

echo "Building Search My Mac with Developer ID signing…"
env \
  SMM_APP_ROOT="$APP_PATH" \
  SMM_CONFIGURATION=release \
  SMM_DISTRIBUTION_SIGNING=1 \
  SMM_CODESIGN_IDENTITY="$SIGNING_IDENTITY" \
  "$PROJECT_ROOT/scripts/build-app.sh"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
if ! grep -Fq 'Authority=Developer ID Application:' <<<"$SIGNATURE_INFO"; then
  echo "The distribution app is not signed with a Developer ID Application certificate." >&2
  exit 1
fi

ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ARCHIVE_PATH"
echo "Submitting $(basename "$NOTARY_ARCHIVE_PATH") to Apple notarization…"
if [[ -n "${SMM_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$NOTARY_ARCHIVE_PATH" \
    --keychain-profile "$SMM_NOTARY_PROFILE" \
    --wait
elif command -v asc >/dev/null; then
  asc notarization submit \
    --file "$NOTARY_ARCHIVE_PATH" \
    --wait \
    --poll-interval "${SMM_NOTARIZATION_POLL_INTERVAL:-30s}" \
    --timeout "${SMM_NOTARIZATION_TIMEOUT:-1h}"
else
  echo "Install asc or set SMM_NOTARY_PROFILE to a notarytool Keychain profile." >&2
  exit 1
fi

STAPLED=0
for ATTEMPT in {1..6}; do
  if xcrun stapler staple "$APP_PATH"; then
    STAPLED=1
    break
  fi
  if [[ "$ATTEMPT" -lt 6 ]]; then
    echo "Notarization ticket is not available to staple yet; retrying in 10 seconds…" >&2
    sleep 10
  fi
done
if [[ "$STAPLED" != "1" ]]; then
  echo "Apple accepted the submission, but its stapling ticket was not available after 60 seconds." >&2
  echo "Rerun this script; it will produce a fresh notarized archive." >&2
  exit 1
fi
xcrun stapler validate "$APP_PATH"
spctl -a -vvv -t execute "$APP_PATH"

ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
rm -f "$NOTARY_ARCHIVE_PATH"
echo "Notarized archive ready: $ARCHIVE_PATH"
