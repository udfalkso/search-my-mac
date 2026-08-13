#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_ROOT="${SMM_APP_ROOT:-$BUILD_ROOT/Search My Mac.app}"
case "$APP_ROOT" in
  */Search\ My\ Mac.app) ;;
  *)
    echo "SMM_APP_ROOT must end in 'Search My Mac.app': $APP_ROOT" >&2
    exit 1
    ;;
esac
XPC_ROOT="$APP_ROOT/Contents/XPCServices/com.searchmymac.app.engine.xpc"
LOCAL_SIGNING_CONFIG="${SMM_SIGNING_CONFIG:-$PROJECT_ROOT/.smm-signing.env}"
# A worktree may deliberately assemble over the stable bundle in the primary
# checkout so macOS keeps the app's TCC identity and folder grants. Reuse that
# checkout's ignored signing configuration when the worktree has none, rather
# than silently falling back to a new ad-hoc identity on every rebuild.
if [[ -z "${SMM_SIGNING_CONFIG:-}" && ! -f "$LOCAL_SIGNING_CONFIG" ]]; then
  OUTPUT_PROJECT_ROOT="$(dirname "$(dirname "$APP_ROOT")")"
  OUTPUT_SIGNING_CONFIG="$OUTPUT_PROJECT_ROOT/.smm-signing.env"
  if [[ -f "$OUTPUT_SIGNING_CONFIG" ]]; then
    LOCAL_SIGNING_CONFIG="$OUTPUT_SIGNING_CONFIG"
  fi
fi
CONFIG_SIGNING_IDENTITY=""
CONFIG_TEAM_IDENTIFIER=""
CONFIG_DISTRIBUTION_SIGNING=""
if [[ -f "$LOCAL_SIGNING_CONFIG" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      SMM_CODESIGN_IDENTITY) CONFIG_SIGNING_IDENTITY="$value" ;;
      SMM_TEAM_ID) CONFIG_TEAM_IDENTIFIER="$value" ;;
      SMM_DISTRIBUTION_SIGNING) CONFIG_DISTRIBUTION_SIGNING="$value" ;;
    esac
  done < "$LOCAL_SIGNING_CONFIG"
fi
SIGNING_IDENTITY="${SMM_CODESIGN_IDENTITY:-${CONFIG_SIGNING_IDENTITY:--}}"
TEAM_IDENTIFIER="${SMM_TEAM_ID:-$CONFIG_TEAM_IDENTIFIER}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Warning: ad-hoc signing changes the app's macOS permission identity on every rebuild." >&2
fi
BUILD_CONFIGURATION="${SMM_CONFIGURATION:-debug}"
PRIVATE_ENTITLEMENTS="${SMM_PRIVATE_ENTITLEMENTS:-0}"
DISTRIBUTION_SIGNING="${SMM_DISTRIBUTION_SIGNING:-${CONFIG_DISTRIBUTION_SIGNING:-0}}"
if [[ -x /opt/homebrew/opt/rust/bin/cargo ]]; then
  CARGO_BIN=/opt/homebrew/opt/rust/bin/cargo
  RUSTC_BIN=/opt/homebrew/opt/rust/bin/rustc
else
  CARGO_BIN="$(command -v cargo)"
  RUSTC_BIN="$(command -v rustc)"
fi

cd "$PROJECT_ROOT"
CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache" swift build \
  -c "$BUILD_CONFIGURATION" \
  --disable-sandbox \
  --cache-path "$BUILD_ROOT/cache" \
  --config-path "$BUILD_ROOT/config" \
  --security-path "$BUILD_ROOT/security"
BIN_PATH="$(CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache" swift build -c "$BUILD_CONFIGURATION" --show-bin-path --disable-sandbox --cache-path "$BUILD_ROOT/cache" --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security")"
RUSTC="$RUSTC_BIN" "$CARGO_BIN" build --locked --release --manifest-path "$PROJECT_ROOT/rust-engine/Cargo.toml"

rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Helpers" "$APP_ROOT/Contents/Resources" "$APP_ROOT/Contents/Frameworks" "$XPC_ROOT/Contents/MacOS" "$XPC_ROOT/Contents/Frameworks"
cp "$PROJECT_ROOT/Resources/App/Info.plist" "$APP_ROOT/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/App/AppIcon.icns" "$APP_ROOT/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/Resources/EngineXPC/Info.plist" "$XPC_ROOT/Contents/Info.plist"
cp "$BIN_PATH/SearchMyMac" "$APP_ROOT/Contents/MacOS/SearchMyMac"
cp "$BIN_PATH/smm" "$APP_ROOT/Contents/Helpers/smm"
cp "$BIN_PATH/SearchMyMacEngineService" "$XPC_ROOT/Contents/MacOS/SearchMyMacEngineService"
cp "$PROJECT_ROOT/rust-engine/target/release/libsearchmymac_engine.dylib" "$APP_ROOT/Contents/Frameworks/libsearchmymac_engine.dylib"
cp "$PROJECT_ROOT/rust-engine/target/release/libsearchmymac_engine.dylib" "$XPC_ROOT/Contents/Frameworks/libsearchmymac_engine.dylib"
if [[ ! -d "$BIN_PATH/llama.framework" ]]; then
  echo "SwiftPM did not stage llama.framework beside the built executables." >&2
  exit 1
fi
cp -R "$BIN_PATH/llama.framework" "$APP_ROOT/Contents/Frameworks/llama.framework"
cp -R "$BIN_PATH/llama.framework" "$XPC_ROOT/Contents/Frameworks/llama.framework"
if [[ ! -d "$BIN_PATH/Sparkle.framework" ]]; then
  echo "SwiftPM did not stage Sparkle.framework beside the app executable." >&2
  exit 1
fi
# ditto preserves the framework's versioned symlinks and executable bits,
# which are part of both Sparkle's runtime layout and its code signature.
ditto "$BIN_PATH/Sparkle.framework" "$APP_ROOT/Contents/Frameworks/Sparkle.framework"

# SwiftPM's executable products only carry @loader_path by default. Bundled
# frameworks live one level above MacOS, so add the standard app-bundle rpath
# before signing or dyld will abort before main() is reached.
for EXECUTABLE in \
  "$APP_ROOT/Contents/MacOS/SearchMyMac" \
  "$APP_ROOT/Contents/Helpers/smm" \
  "$XPC_ROOT/Contents/MacOS/SearchMyMacEngineService"; do
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
  if ! otool -l "$EXECUTABLE" | grep -Fq "path @executable_path/../Frameworks"; then
    echo "Required bundled-framework rpath is missing from $EXECUTABLE" >&2
    exit 1
  fi
done

if [[ -n "$TEAM_IDENTIFIER" ]]; then
  CLIENT_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and identifier \"com.searchmymac.app\""
  ENGINE_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and identifier \"com.searchmymac.app.engine\""
  if [[ "$PRIVATE_ENTITLEMENTS" == "1" ]]; then
    CLIENT_REQUIREMENT="$CLIENT_REQUIREMENT and entitlement[\"com.searchmymac.client\"] = true"
    ENGINE_REQUIREMENT="$ENGINE_REQUIREMENT and entitlement[\"com.searchmymac.engine\"] = true"
    APP_ENTITLEMENTS="$PROJECT_ROOT/Resources/Entitlements/SearchMyMac.entitlements"
    ENGINE_ENTITLEMENTS="$PROJECT_ROOT/Resources/Entitlements/Engine.entitlements"
  else
    APP_ENTITLEMENTS="$PROJECT_ROOT/Resources/Entitlements/SearchMyMacDevelopment.entitlements"
    ENGINE_ENTITLEMENTS="$PROJECT_ROOT/Resources/Entitlements/EngineDevelopment.entitlements"
  fi
else
  # AMFI rejects unknown/custom restricted entitlements on ad-hoc signatures.
  # Development still authenticates the two bundled identifiers; Team ID plus
  # private-entitlement pinning is enabled only for provisioned release signing.
  CLIENT_REQUIREMENT='identifier "com.searchmymac.app"'
  ENGINE_REQUIREMENT='identifier "com.searchmymac.app.engine"'
  APP_ENTITLEMENTS="$PROJECT_ROOT/Resources/Entitlements/SearchMyMacDevelopment.entitlements"
  ENGINE_ENTITLEMENTS="$PROJECT_ROOT/Resources/Entitlements/EngineDevelopment.entitlements"
fi

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
    echo "Configured signing identity is unavailable: $SIGNING_IDENTITY" >&2
    exit 1
  fi
  if [[ -z "$TEAM_IDENTIFIER" ]]; then
    echo "SMM_TEAM_ID is required when using a signing certificate." >&2
    exit 1
  fi
fi
if [[ "$DISTRIBUTION_SIGNING" == "1" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Distribution signing requires a Developer ID Application identity." >&2
    exit 1
  fi
  SIGNING_IDENTITY_DESCRIPTION="$(security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" || true)"
  if ! grep -Fq 'Developer ID Application' <<<"$SIGNING_IDENTITY_DESCRIPTION"; then
    echo "SMM_DISTRIBUTION_SIGNING requires a Developer ID Application identity." >&2
    exit 1
  fi
fi
/usr/libexec/PlistBuddy -c "Set :SMMAuthorizedClientRequirement $CLIENT_REQUIREMENT" "$XPC_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SMMEngineSigningRequirement $ENGINE_REQUIREMENT" "$APP_ROOT/Contents/Info.plist"

CODESIGN_ARGUMENTS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$DISTRIBUTION_SIGNING" == "1" ]]; then
  CODESIGN_ARGUMENTS+=(--options runtime --timestamp)
fi

# TCC remembers a code requirement, not a binary hash. The default designated
# requirement generated for Apple Development and Developer ID certificates is
# intentionally different, so switching between them makes macOS treat a
# rebuild as a new requester for Desktop, Documents, and Downloads. Pin one
# explicit, team-scoped requirement for every signed development or release
# build. It accepts either Apple certificate class for this team, while still
# requiring this exact bundle identifier.
APP_REQUIREMENTS=()
ENGINE_REQUIREMENTS=()
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  APP_REQUIREMENTS=(--requirements "=designated => anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and identifier \"com.searchmymac.app\"")
  ENGINE_REQUIREMENTS=(--requirements "=designated => anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\" and identifier \"com.searchmymac.app.engine\"")
fi

codesign "${CODESIGN_ARGUMENTS[@]}" "$APP_ROOT/Contents/Frameworks/libsearchmymac_engine.dylib"
codesign "${CODESIGN_ARGUMENTS[@]}" "$XPC_ROOT/Contents/Frameworks/libsearchmymac_engine.dylib"
codesign "${CODESIGN_ARGUMENTS[@]}" "$APP_ROOT/Contents/Frameworks/llama.framework"
codesign "${CODESIGN_ARGUMENTS[@]}" "$XPC_ROOT/Contents/Frameworks/llama.framework"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SPARKLE_VERSION_ROOT="$APP_ROOT/Contents/Frameworks/Sparkle.framework/Versions/B"
  # Sparkle's helpers have different signing requirements. Sign them in the
  # documented inside-out order and preserve Downloader's shipped entitlement.
  codesign "${CODESIGN_ARGUMENTS[@]}" "$SPARKLE_VERSION_ROOT/XPCServices/Installer.xpc"
  codesign "${CODESIGN_ARGUMENTS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION_ROOT/XPCServices/Downloader.xpc"
  codesign "${CODESIGN_ARGUMENTS[@]}" "$SPARKLE_VERSION_ROOT/Autoupdate"
  codesign "${CODESIGN_ARGUMENTS[@]}" "$SPARKLE_VERSION_ROOT/Updater.app"
  codesign "${CODESIGN_ARGUMENTS[@]}" "$APP_ROOT/Contents/Frameworks/Sparkle.framework"
fi
codesign "${CODESIGN_ARGUMENTS[@]}" --identifier "com.searchmymac.cli" "$APP_ROOT/Contents/Helpers/smm"
codesign "${CODESIGN_ARGUMENTS[@]}" "${ENGINE_REQUIREMENTS[@]}" --entitlements "$ENGINE_ENTITLEMENTS" "$XPC_ROOT"
codesign "${CODESIGN_ARGUMENTS[@]}" "${APP_REQUIREMENTS[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_ROOT"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  EXPECTED_APP_REQUIREMENT="designated => anchor apple generic and certificate leaf[subject.OU] = $TEAM_IDENTIFIER and identifier \"com.searchmymac.app\""
  EXPECTED_ENGINE_REQUIREMENT="designated => anchor apple generic and certificate leaf[subject.OU] = $TEAM_IDENTIFIER and identifier \"com.searchmymac.app.engine\""
  ACTUAL_APP_REQUIREMENT="$(codesign -d -r- "$APP_ROOT" 2>&1 | sed -n 's/^designated => /designated => /p')"
  ACTUAL_ENGINE_REQUIREMENT="$(codesign -d -r- "$XPC_ROOT" 2>&1 | sed -n 's/^designated => /designated => /p')"
  if [[ "$ACTUAL_APP_REQUIREMENT" != "$EXPECTED_APP_REQUIREMENT" || "$ACTUAL_ENGINE_REQUIREMENT" != "$EXPECTED_ENGINE_REQUIREMENT" ]]; then
    echo "The signed bundle does not have the stable TCC designated requirement." >&2
    exit 1
  fi
fi

echo "$APP_ROOT"
