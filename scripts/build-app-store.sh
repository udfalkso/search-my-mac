#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_CONFIG="${SMM_APP_STORE_SIGNING_CONFIG:-$PROJECT_ROOT/.asc/app-store-signing.env}"
if [[ -f "$SIGNING_CONFIG" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      SMM_CODESIGN_IDENTITY|SMM_TEAM_ID|SMM_APP_STORE_PROFILE|SMM_INSTALLER_IDENTITY)
        if [[ -z "${!key:-}" ]]; then export "$key=$value"; fi ;;
    esac
  done < "$SIGNING_CONFIG"
fi
: "${SMM_CODESIGN_IDENTITY:?Set the personal team's Mac App Store application distribution identity}"
: "${SMM_TEAM_ID:?Set Udi Falkson's personal Apple Developer Team ID}"
: "${SMM_APP_STORE_PROFILE:?Set the Mac App Store provisioning profile path}"
: "${SMM_INSTALLER_IDENTITY:?Set the Mac App Store installer distribution identity}"
export SMM_APP_STORE=1
export SMM_CONFIGURATION=release
export SMM_DISTRIBUTION_SIGNING=0
export SMM_PRIVATE_ENTITLEMENTS=0
export SMM_APP_ROOT="$PROJECT_ROOT/.build/app-store/Search My Mac.app"
bash "$PROJECT_ROOT/scripts/build-app.sh"
codesign --verify --deep --strict --verbose=2 "$SMM_APP_ROOT"
productbuild --component "$SMM_APP_ROOT" /Applications \
  --sign "$SMM_INSTALLER_IDENTITY" "$PROJECT_ROOT/.build/app-store/Search My Mac.pkg"
pkgutil --check-signature "$PROJECT_ROOT/.build/app-store/Search My Mac.pkg"
