#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_ROOT="$BUILD_ROOT/Search My Mac.app"
XPC_ROOT="$APP_ROOT/Contents/XPCServices/com.searchmymac.app.engine.xpc"
LOCAL_SIGNING_CONFIG="$PROJECT_ROOT/.smm-signing.env"
CONFIG_SIGNING_IDENTITY=""
CONFIG_TEAM_IDENTIFIER=""
if [[ -f "$LOCAL_SIGNING_CONFIG" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      SMM_CODESIGN_IDENTITY) CONFIG_SIGNING_IDENTITY="$value" ;;
      SMM_TEAM_ID) CONFIG_TEAM_IDENTIFIER="$value" ;;
    esac
  done < "$LOCAL_SIGNING_CONFIG"
fi
SIGNING_IDENTITY="${SMM_CODESIGN_IDENTITY:-${CONFIG_SIGNING_IDENTITY:--}}"
TEAM_IDENTIFIER="${SMM_TEAM_ID:-$CONFIG_TEAM_IDENTIFIER}"
BUILD_CONFIGURATION="${SMM_CONFIGURATION:-debug}"
PRIVATE_ENTITLEMENTS="${SMM_PRIVATE_ENTITLEMENTS:-0}"

cd "$PROJECT_ROOT"
CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache" swift build \
  -c "$BUILD_CONFIGURATION" \
  --disable-sandbox \
  --cache-path "$BUILD_ROOT/cache" \
  --config-path "$BUILD_ROOT/config" \
  --security-path "$BUILD_ROOT/security"
BIN_PATH="$(CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache" swift build -c "$BUILD_CONFIGURATION" --show-bin-path --disable-sandbox --cache-path "$BUILD_ROOT/cache" --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security")"
cargo build --locked --release --manifest-path "$PROJECT_ROOT/rust-engine/Cargo.toml"

rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources" "$APP_ROOT/Contents/Frameworks" "$XPC_ROOT/Contents/MacOS" "$XPC_ROOT/Contents/Frameworks"
cp "$PROJECT_ROOT/Resources/App/Info.plist" "$APP_ROOT/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/App/AppIcon.icns" "$APP_ROOT/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/Resources/EngineXPC/Info.plist" "$XPC_ROOT/Contents/Info.plist"
cp "$BIN_PATH/SearchMyMac" "$APP_ROOT/Contents/MacOS/SearchMyMac"
cp "$BIN_PATH/SearchMyMacEngineService" "$XPC_ROOT/Contents/MacOS/SearchMyMacEngineService"
cp "$PROJECT_ROOT/rust-engine/target/release/libsearchmymac_engine.dylib" "$XPC_ROOT/Contents/Frameworks/libsearchmymac_engine.dylib"
if [[ ! -d "$BIN_PATH/llama.framework" ]]; then
  echo "SwiftPM did not stage llama.framework beside the built executables." >&2
  exit 1
fi
cp -R "$BIN_PATH/llama.framework" "$APP_ROOT/Contents/Frameworks/llama.framework"
cp -R "$BIN_PATH/llama.framework" "$XPC_ROOT/Contents/Frameworks/llama.framework"

# SwiftPM's executable products only carry @loader_path by default. Bundled
# frameworks live one level above MacOS, so add the standard app-bundle rpath
# before signing or dyld will abort before main() is reached.
for EXECUTABLE in \
  "$APP_ROOT/Contents/MacOS/SearchMyMac" \
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
/usr/libexec/PlistBuddy -c "Set :SMMAuthorizedClientRequirement $CLIENT_REQUIREMENT" "$XPC_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SMMEngineSigningRequirement $ENGINE_REQUIREMENT" "$APP_ROOT/Contents/Info.plist"

codesign --force --sign "$SIGNING_IDENTITY" "$XPC_ROOT/Contents/Frameworks/libsearchmymac_engine.dylib"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_ROOT/Contents/Frameworks/llama.framework"
codesign --force --sign "$SIGNING_IDENTITY" "$XPC_ROOT/Contents/Frameworks/llama.framework"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENGINE_ENTITLEMENTS" "$XPC_ROOT"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$APP_ENTITLEMENTS" "$APP_ROOT"

echo "$APP_ROOT"
