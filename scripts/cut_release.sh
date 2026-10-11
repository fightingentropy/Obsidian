#!/bin/zsh
set -euo pipefail

function usage() {
  cat <<'EOF'
Usage: ./scripts/cut_release.sh [options]

Builds the current Release app, uploads Sparkle assets to GitHub Releases,
regenerates the appcast, and syncs the root appcast feed used by the app.

Environment:
  SPARKLE_PRIVATE_KEY               Required. Private Sparkle signing key used for this release
  SPARKLE_FEED_URL                  Optional. Feed URL embedded into the release app
  SPARKLE_KEY_ACCOUNT               Optional. Keychain account name used to derive the public key
  APPCAST_LINK_URL                  Optional. Project link embedded in the appcast (default: https://github.com/<repo>)

Options:
  --notes-file <path>               Copy release notes from this file to releases/Obsidian-<version>.md
  --archives-dir <path>             Local cache for archives and generated appcast (default: .release-assets)
  --derived-data-path <path>        Derived data path for the build (default: .release-build)
  --repo <owner/repo>               GitHub repository used for release uploads (default: current gh repo)
  --release-notes-url-prefix <url>  Public release notes URL prefix (default: GitHub raw main/releases)
  --force                           Replace the zip and delta assets of a GitHub Release that already exists for this version
  --skip-github-release             Build and generate a local appcast without uploading assets or touching root appcast
  -h, --help                        Show this help
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVES_DIR="$ROOT_DIR/.release-assets"
DERIVED_DATA_PATH="$ROOT_DIR/.release-build"
REPO=""
RELEASE_NOTES_URL_PREFIX=""
NOTES_FILE=""
FORCE=false
PUBLISH_GITHUB_RELEASE=true
RELEASE_EXISTS=false
# Sparkle's generate_appcast builds deltas from the newest 5 archives by
# default (--maximum-deltas), so older releases do not need to be downloaded.
RELEASE_HISTORY_LIMIT=5
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-}"

function require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required tool not found: $1" >&2
    exit 1
  fi
}

function require_gh_auth() {
  require_tool gh
  # Check only the active account on the host this script talks to. A bare
  # `gh auth status` also fails when an unrelated stored account or host has
  # an expired token. gh prints the reason to stderr when the check fails.
  local host="${GH_HOST:-github.com}"
  if ! gh auth status --active --hostname "$host" >/dev/null; then
    echo "GitHub CLI is not authenticated for $host; run 'gh auth login' before cutting a release." >&2
    exit 1
  fi
}

function expected_marketing_version() {
  sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$ROOT_DIR/project.yml" | head -n 1
}

function sync_release_notes() {
  mkdir -p "$ARCHIVES_DIR"
  rm -f "$ARCHIVES_DIR"/Markdown-*.md(N) "$ARCHIVES_DIR"/Obsidian-*.md(N)
  for notes in "$ROOT_DIR"/releases/Markdown-*.md(N) "$ROOT_DIR"/releases/Obsidian-*.md(N); do
    cp "$notes" "$ARCHIVES_DIR/"
  done
}

function check_existing_release() {
  local tag="v$EXPECTED_VERSION"
  local view_errors
  if view_errors="$(gh release view "$tag" --repo "$REPO" 2>&1 >/dev/null)"; then
    RELEASE_EXISTS=true
  elif [[ "$view_errors" != *"release not found"* ]]; then
    echo "Could not check whether GitHub release $tag exists in $REPO:" >&2
    echo "$view_errors" >&2
    exit 1
  fi

  if [[ "$RELEASE_EXISTS" == true ]]; then
    if [[ "$FORCE" == true ]]; then
      echo "GitHub release $tag already exists in $REPO; replacing its zip and delta assets because --force was passed." >&2
    else
      echo "GitHub release $tag already exists in $REPO." >&2
      echo "Bump MARKETING_VERSION in project.yml, or pass --force to replace the existing release assets." >&2
      exit 1
    fi
  fi
}

function download_existing_release_assets() {
  local listing
  if ! listing="$(gh release list --repo "$REPO" --limit "$RELEASE_HISTORY_LIMIT" --json tagName --jq '.[].tagName')"; then
    echo "Could not list GitHub releases for $REPO." >&2
    exit 1
  fi

  local tag
  for tag in "${(@f)listing}"; do
    [[ -n "$tag" ]] || continue
    # The release being cut is rebuilt locally. Its published assets (a
    # --force run) are stale, and old deltas would be reused by
    # generate_appcast instead of being regenerated from the new archive.
    if [[ "$tag" == "v$EXPECTED_VERSION" ]]; then
      continue
    fi
    gh release download "$tag" \
      --repo "$REPO" \
      --pattern "*.zip" \
      --pattern "*.delta" \
      --dir "$ARCHIVES_DIR" \
      --clobber >/dev/null
  done
}

# Removes the delta assets of the release being replaced, so a --force run
# never leaves deltas that patch an earlier build of the same version.
function delete_existing_delta_assets() {
  local tag="v$VERSION"
  local names
  if ! names="$(gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name')"; then
    echo "Could not list the assets of GitHub release $tag in $REPO." >&2
    exit 1
  fi

  local name
  for name in "${(@f)names}"; do
    [[ "$name" == *.delta ]] || continue
    gh release delete-asset "$tag" "$name" --repo "$REPO" --yes >/dev/null
  done
}

function upload_current_release_assets() {
  local tag="v$VERSION"
  local title="Obsidian $VERSION"
  local delta_files=("$ARCHIVES_DIR"/Obsidian${BUILD}-*.delta(N))

  if [[ "$RELEASE_EXISTS" == true ]]; then
    delete_existing_delta_assets
    gh release edit "$tag" --repo "$REPO" --title "$title" --notes-file "$DEFAULT_NOTES_PATH" >/dev/null
    if (( ${#delta_files[@]} > 0 )); then
      gh release upload "$tag" --repo "$REPO" "$ARCHIVE_PATH" "${delta_files[@]}" --clobber >/dev/null
    else
      gh release upload "$tag" --repo "$REPO" "$ARCHIVE_PATH" --clobber >/dev/null
    fi
  else
    if (( ${#delta_files[@]} > 0 )); then
      gh release create "$tag" --repo "$REPO" --title "$title" --notes-file "$DEFAULT_NOTES_PATH" "$ARCHIVE_PATH" "${delta_files[@]}" >/dev/null
    else
      gh release create "$tag" --repo "$REPO" --title "$title" --notes-file "$DEFAULT_NOTES_PATH" "$ARCHIVE_PATH" >/dev/null
    fi
  fi
}

function sync_root_appcast() {
  cp "$ARCHIVES_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file)
      NOTES_FILE="$2"
      shift 2
      ;;
    --archives-dir)
      ARCHIVES_DIR="$2"
      shift 2
      ;;
    --derived-data-path)
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --release-notes-url-prefix)
      RELEASE_NOTES_URL_PREFIX="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift 1
      ;;
    --skip-github-release)
      PUBLISH_GITHUB_RELEASE=false
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_tool xcodegen
require_tool xcodebuild
require_tool python3

# gh is needed to publish, and to discover the repository when no --repo or
# notes URL prefix was given.
if [[ "$PUBLISH_GITHUB_RELEASE" == true || ( -z "$REPO" && -z "$RELEASE_NOTES_URL_PREFIX" ) ]]; then
  require_gh_auth
  if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
  fi
fi

if [[ -z "$RELEASE_NOTES_URL_PREFIX" ]]; then
  if [[ -n "$REPO" ]]; then
    RELEASE_NOTES_URL_PREFIX="https://raw.githubusercontent.com/$REPO/main/releases"
  else
    RELEASE_NOTES_URL_PREFIX="https://example.invalid/releases"
  fi
fi

if [[ -z "$SPARKLE_FEED_URL" ]]; then
  if [[ -n "$REPO" ]]; then
    SPARKLE_FEED_URL="https://raw.githubusercontent.com/$REPO/main/appcast.xml"
  else
    SPARKLE_FEED_URL="https://example.invalid/appcast.xml"
  fi
fi

if [[ -z "$SPARKLE_PRIVATE_KEY" ]]; then
  echo "SPARKLE_PRIVATE_KEY must be set for release builds." >&2
  exit 1
fi

if [[ -z "$SPARKLE_KEY_ACCOUNT" ]]; then
  if [[ -n "$REPO" ]]; then
    SPARKLE_KEY_ACCOUNT="${REPO##*/}-sparkle"
  else
    SPARKLE_KEY_ACCOUNT="markdown-sparkle"
  fi
fi

# Read the version before building so an already-published version aborts
# before any archives are downloaded or compiled.
EXPECTED_VERSION="$(expected_marketing_version)"
if [[ -z "$EXPECTED_VERSION" ]]; then
  echo "Could not read MARKETING_VERSION from $ROOT_DIR/project.yml" >&2
  exit 1
fi

mkdir -p "$ARCHIVES_DIR"
sync_release_notes

if [[ "$PUBLISH_GITHUB_RELEASE" == true ]]; then
  check_existing_release
  download_existing_release_assets
fi

cd "$ROOT_DIR"
xcodegen

if [[ -d "$DERIVED_DATA_PATH" ]]; then
  SPARKLE_BIN_DIR="$(find "$DERIVED_DATA_PATH" -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)"
else
  SPARKLE_BIN_DIR=""
fi
if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  xcodebuild \
    -project Obsidian.xcodeproj \
    -scheme Obsidian \
    -resolvePackageDependencies \
    -derivedDataPath "$DERIVED_DATA_PATH" >/dev/null
  SPARKLE_BIN_DIR="$(find "$DERIVED_DATA_PATH" -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)"
fi

if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  echo "Could not locate Sparkle binaries under $DERIVED_DATA_PATH" >&2
  exit 1
fi

SPARKLE_PRIVATE_KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/markdown-sparkle-key.XXXXXX")"
cleanup() {
  rm -f "$SPARKLE_PRIVATE_KEY_FILE"
}
trap cleanup EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_PRIVATE_KEY_FILE"

"$SPARKLE_BIN_DIR/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -f "$SPARKLE_PRIVATE_KEY_FILE" >/dev/null
SPARKLE_PUBLIC_ED_KEY="$("$SPARKLE_BIN_DIR/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p | tr -d '\n')"

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "Could not derive Sparkle public key" >&2
  exit 1
fi

xcodebuild \
  -project Obsidian.xcodeproj \
  -scheme Obsidian \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Obsidian.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at $APP_PATH" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
if [[ "$VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Built app reports version $VERSION but project.yml sets MARKETING_VERSION $EXPECTED_VERSION" >&2
  exit 1
fi
ARCHIVE_PATH="$ARCHIVES_DIR/Obsidian-$VERSION.zip"
DEFAULT_NOTES_PATH="$ROOT_DIR/releases/Obsidian-$VERSION.md"

if [[ -n "$NOTES_FILE" ]]; then
  mkdir -p "$ROOT_DIR/releases"
  if [[ "${NOTES_FILE:A}" != "${DEFAULT_NOTES_PATH:A}" ]]; then
    cp "$NOTES_FILE" "$DEFAULT_NOTES_PATH"
  fi
elif [[ ! -f "$DEFAULT_NOTES_PATH" ]]; then
  echo "Release notes missing: $DEFAULT_NOTES_PATH" >&2
  echo "Create that file or pass --notes-file <path>." >&2
  exit 1
fi

cp "$DEFAULT_NOTES_PATH" "$ARCHIVES_DIR/"

rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

# Deltas that end at this build are derived from the archive just built, but
# generate_appcast reuses any delta file already on disk. Drop leftovers from
# an earlier run so they are regenerated against the new archive.
rm -f "$ARCHIVES_DIR"/Obsidian${BUILD}-*.delta(N)

# APPCAST_REPO drives generate_appcast.sh's default URLs and project link; it
# falls back to the script's built-in repository when no repo is known here.
SPARKLE_BIN="$SPARKLE_BIN_DIR/generate_appcast" \
APPCAST_REPO="$REPO" \
"$ROOT_DIR/scripts/generate_appcast.sh" \
  "$ARCHIVES_DIR" \
  "https://example.invalid/releases" \
  "$RELEASE_NOTES_URL_PREFIX" \
  "$SPARKLE_PRIVATE_KEY_FILE"

if [[ "$PUBLISH_GITHUB_RELEASE" == true ]]; then
  # Upload after generate_appcast so the freshly generated deltas, which the
  # rewritten appcast points at, are published with the archive.
  upload_current_release_assets
  python3 "$ROOT_DIR/scripts/rewrite_appcast_for_github_releases.py" "$ARCHIVES_DIR/appcast.xml" "$REPO"
  sync_root_appcast
fi

echo "Built Obsidian $VERSION ($BUILD)"
echo "Archive cache: $ARCHIVE_PATH"
echo "Release notes: $DEFAULT_NOTES_PATH"
echo "Appcast cache: $ARCHIVES_DIR/appcast.xml"
if [[ "$PUBLISH_GITHUB_RELEASE" == true ]]; then
  echo "Root feed: $ROOT_DIR/appcast.xml"
  echo "GitHub release: https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "Root feed unchanged (--skip-github-release)"
fi
