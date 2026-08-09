#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_ROOT="$BUILD_ROOT/Search My Mac.app"
STAGING_ROOT="$BUILD_ROOT/installer-root"
PACKAGE_PATH="$BUILD_ROOT/Search My Mac.pkg"
INSTALLER_IDENTITY="${SMM_INSTALLER_IDENTITY:-}"

"$PROJECT_ROOT/scripts/build-app.sh"

rm -rf "$STAGING_ROOT" "$PACKAGE_PATH"
mkdir -p "$STAGING_ROOT/Applications" "$STAGING_ROOT/usr/local/bin"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP_ROOT" "$STAGING_ROOT/Applications/Search My Mac.app"
xattr -cr "$STAGING_ROOT"
ln -s "/Applications/Search My Mac.app/Contents/Helpers/smm" "$STAGING_ROOT/usr/local/bin/smm"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_ROOT/Contents/Info.plist")"
PKG_ARGUMENTS=(
  --root "$STAGING_ROOT"
  --identifier "com.searchmymac.installer"
  --version "$VERSION"
  --install-location "/"
  --filter '(^|/)\._'
)
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  PKG_ARGUMENTS+=(--sign "$INSTALLER_IDENTITY")
fi

COPYFILE_DISABLE=1 pkgbuild "${PKG_ARGUMENTS[@]}" "$PACKAGE_PATH"
echo "$PACKAGE_PATH"
