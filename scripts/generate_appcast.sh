#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
Usage: generate_appcast.sh <archives-dir> [download-url-prefix] [release-notes-url-prefix] [ed-key-file] [link-url]

Environment:
  APPCAST_REPO              GitHub owner/repo behind the default URLs (default: fightingentropy/Obsidian)
  APPCAST_LINK_URL          Project link embedded in the appcast (default: https://github.com/<APPCAST_REPO>)
  SPARKLE_PRIVATE_KEY_FILE  Fallback for [ed-key-file]
  SPARKLE_BIN               Sparkle generate_appcast binary (default: .derived SwiftPM artifacts)
EOF
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVES_DIR="$1"
REPO="${APPCAST_REPO:-fightingentropy/Obsidian}"
DOWNLOAD_URL_PREFIX="${2:-https://raw.githubusercontent.com/$REPO/main/releases}"
RELEASE_NOTES_URL_PREFIX="${3:-https://raw.githubusercontent.com/$REPO/main/releases}"
ED_KEY_FILE="${4:-${SPARKLE_PRIVATE_KEY_FILE:-}}"
LINK_URL="${5:-${APPCAST_LINK_URL:-https://github.com/$REPO}}"
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT_DIR/.derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
OUTPUT_APPCAST="$ARCHIVES_DIR/appcast.xml"

if [[ ! -x "$SPARKLE_BIN" ]]; then
  echo "Sparkle generate_appcast tool not found at $SPARKLE_BIN" >&2
  exit 1
fi

cmd=(
  "$SPARKLE_BIN"
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"
  --release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX"
  --link "$LINK_URL"
)

if [[ -n "$ED_KEY_FILE" ]]; then
  cmd+=(--ed-key-file "$ED_KEY_FILE")
fi

cmd+=("$ARCHIVES_DIR")

"${cmd[@]}"

if [[ "${ARCHIVES_DIR:A}" == "${ROOT_DIR:A}/releases" && -f "$OUTPUT_APPCAST" ]]; then
  cp "$OUTPUT_APPCAST" "$ROOT_DIR/appcast.xml"
  echo "Synced $ROOT_DIR/appcast.xml"
fi
