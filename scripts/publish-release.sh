#!/usr/bin/env bash
set -euo pipefail

# Builds and notarizes the app on this Mac, creates a signed Sparkle appcast,
# then publishes both artifacts to a GitHub Release. GitHub does no building.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_INFO="$PROJECT_ROOT/Resources/App/Info.plist"
ENGINE_INFO="$PROJECT_ROOT/Resources/EngineXPC/Info.plist"
REPOSITORY="${SMM_GITHUB_REPOSITORY:-udfalkso/search-my-mac}"
DRAFT=0
NOTES=""
NOTES_FILE=""
NOTES_SOURCE=""

usage() {
  cat >&2 <<EOF
Usage: $0 (--notes <markdown> | --notes-file <markdown-file>) [--draft]

Builds, signs, notarizes, and publishes the committed version from Info.plist.
Pass short Markdown release notes directly with --notes, or read longer notes
from a file with --notes-file. Specify exactly one notes option.
Use --draft to create a GitHub draft release instead of publishing immediately.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --notes)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      if [[ -n "$NOTES_SOURCE" ]]; then
        echo "Specify exactly one of --notes or --notes-file." >&2
        exit 2
      fi
      NOTES="$2"
      NOTES_SOURCE="string"
      shift 2
      ;;
    --notes-file)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      if [[ -n "$NOTES_SOURCE" ]]; then
        echo "Specify exactly one of --notes or --notes-file." >&2
        exit 2
      fi
      NOTES_FILE="$2"
      NOTES_SOURCE="file"
      shift 2
      ;;
    --draft)
      DRAFT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$NOTES_SOURCE" ]]; then
  echo "Specify exactly one of --notes or --notes-file." >&2
  usage
  exit 2
fi
if [[ "$NOTES_SOURCE" == "string" && -z "$NOTES" ]]; then
  echo "--notes cannot be empty." >&2
  exit 2
fi
if [[ "$NOTES_SOURCE" == "file" ]]; then
  if [[ ! -f "$NOTES_FILE" ]]; then
    echo "Release-notes file does not exist: $NOTES_FILE" >&2
    exit 2
  fi
  NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"
fi

for COMMAND in gh git xmllint; do
  if ! command -v "$COMMAND" >/dev/null; then
    echo "Required command is not installed: $COMMAND" >&2
    if [[ "$COMMAND" == "gh" ]]; then
      echo "Install it with 'brew install gh', then run 'gh auth login'." >&2
    fi
    exit 1
  fi
done

cd "$PROJECT_ROOT"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Tracked files have uncommitted changes. Commit them before publishing." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")"
ENGINE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ENGINE_INFO")"
ENGINE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ENGINE_INFO")"
if [[ "$VERSION" != "$ENGINE_VERSION" || "$BUILD_NUMBER" != "$ENGINE_BUILD" ]]; then
  echo "App and engine versions do not match. Run scripts/set-version.sh first." >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Info.plist has an invalid release version or build number." >&2
  exit 1
fi

TAG="v$VERSION"
COMMIT_SHA="$(git rev-parse HEAD)"
if ! gh api "repos/$REPOSITORY/commits/$COMMIT_SHA" --silent >/dev/null 2>&1; then
  echo "Commit $COMMIT_SHA is not available in $REPOSITORY. Push it before publishing." >&2
  exit 1
fi
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "GitHub Release $TAG already exists." >&2
  exit 1
fi

SPARKLE_TOOLS="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_TOOLS/generate_appcast" ]]; then
  echo "Resolving the pinned Sparkle package and its release tools…"
  CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/clang-cache" swift package \
    --disable-sandbox \
    --cache-path "$PROJECT_ROOT/.build/cache" \
    --config-path "$PROJECT_ROOT/.build/config" \
    --security-path "$PROJECT_ROOT/.build/security" \
    resolve
fi

echo "Building and notarizing Search My Mac $VERSION ($BUILD_NUMBER) locally…"
OUTPUT_ROOT="$PROJECT_ROOT/.build/distribution"
env SMM_DISTRIBUTION_OUTPUT_DIR="$OUTPUT_ROOT" \
  "$PROJECT_ROOT/scripts/notarize-app.sh"

ARCHIVE_PATH="$OUTPUT_ROOT/Search My Mac-$VERSION.zip"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Expected notarized archive was not created: $ARCHIVE_PATH" >&2
  exit 1
fi

RELEASE_ROOT="$OUTPUT_ROOT/github-$TAG"
case "$RELEASE_ROOT" in
  "$PROJECT_ROOT"/.build/distribution/github-v*) ;;
  *) echo "Refusing unsafe release staging path: $RELEASE_ROOT" >&2; exit 1 ;;
esac
rm -rf "$RELEASE_ROOT"
mkdir -p "$RELEASE_ROOT"
ditto "$ARCHIVE_PATH" "$RELEASE_ROOT/$(basename "$ARCHIVE_PATH")"
STAGED_NOTES_PATH="$RELEASE_ROOT/Search My Mac-$VERSION.md"
if [[ "$NOTES_SOURCE" == "string" ]]; then
  printf '%s\n' "$NOTES" > "$STAGED_NOTES_PATH"
else
  ditto "$NOTES_FILE" "$STAGED_NOTES_PATH"
fi

DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$TAG/"
"$SPARKLE_TOOLS/generate_appcast" \
  --account com.searchmymac.app \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/$REPOSITORY" \
  --versions "$BUILD_NUMBER" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$RELEASE_ROOT/appcast.xml" \
  "$RELEASE_ROOT"

APPCAST_PATH="$RELEASE_ROOT/appcast.xml"
xmllint --noout "$APPCAST_PATH"
if ! grep -Fq 'sparkle:edSignature=' "$APPCAST_PATH"; then
  echo "Generated appcast is missing its Ed25519 archive signature." >&2
  exit 1
fi
if ! grep -Fq '<!-- sparkle-signatures:' "$APPCAST_PATH"; then
  echo "Generated appcast is missing its signed-feed signature." >&2
  exit 1
fi

GH_ARGUMENTS=(
  release create "$TAG"
  "$RELEASE_ROOT/$(basename "$ARCHIVE_PATH")"
  "$APPCAST_PATH"
  --repo "$REPOSITORY"
  --target "$COMMIT_SHA"
  --title "Search My Mac $VERSION"
  --notes-file "$STAGED_NOTES_PATH"
)
if [[ "$DRAFT" == "1" ]]; then
  GH_ARGUMENTS+=(--draft)
fi

echo "Publishing GitHub Release $TAG…"
gh "${GH_ARGUMENTS[@]}"
echo "Published https://github.com/$REPOSITORY/releases/tag/$TAG"
if [[ "$DRAFT" == "1" ]]; then
  echo "The update feed will become live when the draft release is published."
else
  echo "Update feed: https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
fi
