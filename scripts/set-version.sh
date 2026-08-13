#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_INFO="$PROJECT_ROOT/Resources/App/Info.plist"
ENGINE_INFO="$PROJECT_ROOT/Resources/EngineXPC/Info.plist"

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <version> <build-number>" >&2
  echo "Example: $0 0.2.0 2" >&2
  exit 2
fi

VERSION="$1"
BUILD_NUMBER="$2"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must contain three numeric components, such as 0.2.0." >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer." >&2
  exit 2
fi

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")"
if [[ "$VERSION" == "$CURRENT_VERSION" ]]; then
  echo "The release version is already $CURRENT_VERSION; choose a newer version." >&2
  exit 2
fi
if (( BUILD_NUMBER <= CURRENT_BUILD )); then
  echo "Build number must be greater than the current build ($CURRENT_BUILD)." >&2
  exit 2
fi

for INFO_PLIST in "$APP_INFO" "$ENGINE_INFO"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
  plutil -lint "$INFO_PLIST" >/dev/null
done

echo "Set Search My Mac to version $VERSION (build $BUILD_NUMBER)."
echo "Review and commit both Info.plist changes before publishing the release."
