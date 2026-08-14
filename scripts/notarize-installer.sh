#!/usr/bin/env bash
set -euo pipefail

# Builds a Developer-ID-signed app, packages it for /Applications, signs the
# package with Developer ID Installer, notarizes it, and staples the ticket.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="${SMM_DISTRIBUTION_OUTPUT_DIR:-$PROJECT_ROOT/.build/distribution}"
APP_PATH="$OUTPUT_ROOT/Search My Mac.app"
STAGING_ROOT="$OUTPUT_ROOT/installer-root"
UNSIGNED_PACKAGE_PATH="$OUTPUT_ROOT/Search My Mac-unsigned.pkg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Resources/App/Info.plist")"
PACKAGE_PATH="$OUTPUT_ROOT/Search My Mac-$VERSION.pkg"

case "$OUTPUT_ROOT" in
  ""|/) echo "Refusing unsafe distribution output directory: $OUTPUT_ROOT" >&2; exit 1 ;;
esac

if [[ -n "${SMM_DISTRIBUTION_SIGNING_IDENTITY:-}" ]]; then
  APPLICATION_IDENTITY="$SMM_DISTRIBUTION_SIGNING_IDENTITY"
else
  mapfile -t APPLICATION_IDENTITIES < <(
    security find-identity -v -p codesigning \
      | awk '/Developer ID Application/ { print $2 }'
  )
  case "${#APPLICATION_IDENTITIES[@]}" in
    1) APPLICATION_IDENTITY="${APPLICATION_IDENTITIES[0]}" ;;
    0)
      echo "No Developer ID Application certificate is installed." >&2
      exit 1
      ;;
    *)
      echo "More than one Developer ID Application certificate is installed." >&2
      echo "Set SMM_DISTRIBUTION_SIGNING_IDENTITY to its SHA-1 fingerprint." >&2
      exit 1
      ;;
  esac
fi

if [[ -n "${SMM_INSTALLER_IDENTITY:-}" ]]; then
  INSTALLER_IDENTITY="$SMM_INSTALLER_IDENTITY"
else
  mapfile -t INSTALLER_IDENTITIES < <(
    security find-identity -v \
      | awk '/Developer ID Installer/ { print $2 }'
  )
  case "${#INSTALLER_IDENTITIES[@]}" in
    1) INSTALLER_IDENTITY="${INSTALLER_IDENTITIES[0]}" ;;
    0)
      echo "No Developer ID Installer certificate is installed." >&2
      exit 1
      ;;
    *)
      echo "More than one Developer ID Installer certificate is installed." >&2
      echo "Set SMM_INSTALLER_IDENTITY to its SHA-1 fingerprint." >&2
      exit 1
      ;;
  esac
fi

if ! security find-identity -v | grep -Fq "$INSTALLER_IDENTITY"; then
  echo "Configured Developer ID Installer identity is unavailable: $INSTALLER_IDENTITY" >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT"
rm -rf "$STAGING_ROOT"
rm -f "$UNSIGNED_PACKAGE_PATH" "$PACKAGE_PATH"

cleanup() {
  rm -rf "$STAGING_ROOT"
  rm -f "$UNSIGNED_PACKAGE_PATH"
}
trap cleanup EXIT

if [[ "${SMM_REUSE_DISTRIBUTION_APP:-0}" == "1" ]]; then
  if [[ ! -d "$APP_PATH" ]]; then
    echo "No existing distribution app is available to package: $APP_PATH" >&2
    exit 1
  fi
  echo "Reusing the existing notarized distribution app…"
else
  echo "Building Search My Mac with Developer ID Application signing…"
  env \
    SMM_APP_ROOT="$APP_PATH" \
    SMM_CONFIGURATION=release \
    SMM_DISTRIBUTION_SIGNING=1 \
    SMM_CODESIGN_IDENTITY="$APPLICATION_IDENTITY" \
    "$PROJECT_ROOT/scripts/build-app.sh"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
APP_SIGNATURE_INFO="$(codesign -dvv "$APP_PATH" 2>&1)"
if ! grep -Fq 'Authority=Developer ID Application:' <<<"$APP_SIGNATURE_INFO"; then
  echo "The packaged app is not signed with a Developer ID Application certificate." >&2
  exit 1
fi
if ! grep -Fq 'Timestamp=' <<<"$APP_SIGNATURE_INFO"; then
  echo "The packaged app signature does not have a secure timestamp." >&2
  exit 1
fi
if [[ "${SMM_REUSE_DISTRIBUTION_APP:-0}" == "1" ]]; then
  xcrun stapler validate "$APP_PATH"
  spctl -a -vvv -t execute "$APP_PATH"
fi

mkdir -p "$STAGING_ROOT/Applications" "$STAGING_ROOT/usr/local/bin"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr \
  "$APP_PATH" \
  "$STAGING_ROOT/Applications/Search My Mac.app"
xattr -cr "$STAGING_ROOT"
ln -s "/Applications/Search My Mac.app/Contents/Helpers/smm" \
  "$STAGING_ROOT/usr/local/bin/smm"

COPYFILE_DISABLE=1 pkgbuild \
  --root "$STAGING_ROOT" \
  --identifier "com.searchmymac.installer" \
  --version "$VERSION" \
  --install-location "/" \
  --filter '(^|/)\._' \
  "$UNSIGNED_PACKAGE_PATH"

echo "Signing installer package with Developer ID Installer…"
productsign \
  --sign "$INSTALLER_IDENTITY" \
  "$UNSIGNED_PACKAGE_PATH" \
  "$PACKAGE_PATH"

PACKAGE_SIGNATURE_INFO="$(pkgutil --check-signature "$PACKAGE_PATH" 2>&1)"
printf '%s\n' "$PACKAGE_SIGNATURE_INFO"
if ! grep -Fq 'Developer ID Installer:' <<<"$PACKAGE_SIGNATURE_INFO"; then
  echo "The package is not signed with a Developer ID Installer certificate." >&2
  exit 1
fi

echo "Submitting $(basename "$PACKAGE_PATH") to Apple notarization…"
if [[ -n "${SMM_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$PACKAGE_PATH" \
    --keychain-profile "$SMM_NOTARY_PROFILE" \
    --wait
elif command -v asc >/dev/null; then
  asc notarization submit \
    --file "$PACKAGE_PATH" \
    --wait \
    --poll-interval "${SMM_NOTARIZATION_POLL_INTERVAL:-30s}" \
    --timeout "${SMM_NOTARIZATION_TIMEOUT:-1h}"
else
  echo "Install asc or set SMM_NOTARY_PROFILE to a notarytool Keychain profile." >&2
  exit 1
fi

STAPLED=0
for ATTEMPT in {1..6}; do
  if xcrun stapler staple "$PACKAGE_PATH"; then
    STAPLED=1
    break
  fi
  if [[ "$ATTEMPT" -lt 6 ]]; then
    echo "Notarization ticket is not available to staple yet; retrying in 10 seconds…" >&2
    sleep 10
  fi
done
if [[ "$STAPLED" != "1" ]]; then
  echo "Apple accepted the package, but its stapling ticket was not available after 60 seconds." >&2
  exit 1
fi

xcrun stapler validate "$PACKAGE_PATH"
spctl -a -vvv -t install "$PACKAGE_PATH"

echo "Notarized installer ready: $PACKAGE_PATH"
