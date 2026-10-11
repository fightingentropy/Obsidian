#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BUILD_ROOT="$ROOT_DIR/.codex-build/local-install"
LOCAL_DERIVED_DATA="$LOCAL_BUILD_ROOT/deriveddata"
LOCAL_SPM_DIR="$LOCAL_BUILD_ROOT/spm"
INSTALL_APP_PATH="/Applications/Obsidian.app"
APP_BUNDLE_IDENTIFIER="com.md.Obsidian"
LOCAL_CODESIGN_IDENTITY="${LOCAL_CODESIGN_IDENTITY:-Obsidian}"

function require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required tool not found: $1" >&2
    exit 1
  fi
}

require_tool security
require_tool xcodegen
require_tool xcodebuild

# Never replace a different app that happens to use the same display name.
if [[ -e "$INSTALL_APP_PATH" ]]; then
  installed_identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INSTALL_APP_PATH/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$installed_identifier" != "$APP_BUNDLE_IDENTIFIER" ]]; then
    echo "A different app already exists at $INSTALL_APP_PATH; leaving it untouched." >&2
    exit 1
  fi
fi

if ! security find-identity -v -p codesigning | grep -F "\"$LOCAL_CODESIGN_IDENTITY\"" >/dev/null; then
  "$ROOT_DIR/scripts/create_local_codesigning_identity.sh" "$LOCAL_CODESIGN_IDENTITY"
fi

rm -rf "$LOCAL_BUILD_ROOT"
mkdir -p "$LOCAL_BUILD_ROOT"

cd "$ROOT_DIR"
xcodegen
xcodebuild \
  -project Obsidian.xcodeproj \
  -scheme Obsidian \
  -configuration Debug \
  -xcconfig "$ROOT_DIR/LocalBuild.xcconfig" \
  -derivedDataPath "$LOCAL_DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$LOCAL_SPM_DIR" \
  CODE_SIGN_IDENTITY="$LOCAL_CODESIGN_IDENTITY" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  build

APP_PATH="$LOCAL_DERIVED_DATA/Build/Products/Debug/Obsidian.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Local app not found at $APP_PATH" >&2
  exit 1
fi

# Ask the existing app to quit so it can save pending note edits.
osascript <<'APPLESCRIPT'
if application id "com.md.Obsidian" is running then
  tell application id "com.md.Obsidian" to quit
end if
APPLESCRIPT

for attempt in {1..80}; do
  if ! pgrep -f '/Applications/Obsidian\.app/Contents/MacOS/Obsidian( |$)' >/dev/null; then
    break
  fi
  sleep 0.25
done
if pgrep -f '/Applications/Obsidian\.app/Contents/MacOS/Obsidian( |$)' >/dev/null; then
  echo "The app is still running; installation stopped to preserve pending edits." >&2
  exit 1
fi

rm -rf "$INSTALL_APP_PATH"
ditto "$APP_PATH" "$INSTALL_APP_PATH"
xattr -cr "$INSTALL_APP_PATH"

open -na "$INSTALL_APP_PATH"

echo "Installed local build to $INSTALL_APP_PATH"
echo "Signing identity: $LOCAL_CODESIGN_IDENTITY"
echo "Sparkle feed disabled for local installs"
