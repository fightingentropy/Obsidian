#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Optional knobs (unset = default xcodebuild behavior):
#   SPM_CLONED_SOURCE_PACKAGES_DIR  directory passed as -clonedSourcePackagesDirPath
#                                   so CI can cache SwiftPM checkouts
#   XCRESULT_PATH                   .xcresult bundle passed as -resultBundlePath
#                                   so CI can upload it when the tests fail
SPM_ARGS=()
if [[ -n "${SPM_CLONED_SOURCE_PACKAGES_DIR:-}" ]]; then
  SPM_ARGS=(-clonedSourcePackagesDirPath "$SPM_CLONED_SOURCE_PACKAGES_DIR")
fi

RESULT_ARGS=()
if [[ -n "${XCRESULT_PATH:-}" ]]; then
  if [[ "$XCRESULT_PATH" != *.xcresult ]]; then
    echo "XCRESULT_PATH must end in .xcresult: $XCRESULT_PATH" >&2
    exit 1
  fi
  # xcodebuild refuses to write into an existing result bundle.
  rm -rf "$XCRESULT_PATH"
  mkdir -p "$(dirname "$XCRESULT_PATH")"
  RESULT_ARGS=(-resultBundlePath "$XCRESULT_PATH")
fi

python3 scripts/check_docs.py

# Obsidian/Info.plist is tracked but generated from project.yml, so
# regenerating it must be a no-op. Snapshot it before xcodegen and diff the
# result: on a clean checkout this is the same as 'git diff --exit-code' against
# the tracked file, and in a working tree it still passes when project.yml and
# the regenerated plist were edited together but not yet staged.
INFO_PLIST="Obsidian/Info.plist"
INFO_PLIST_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/obsidian-info-plist.XXXXXX")"
trap 'rm -f "$INFO_PLIST_SNAPSHOT"' EXIT
cp "$INFO_PLIST" "$INFO_PLIST_SNAPSHOT"

xcodegen generate --quiet --spec project.yml

if ! git diff --no-index --exit-code "$INFO_PLIST_SNAPSHOT" "$INFO_PLIST"; then
  echo "$INFO_PLIST is stale: run 'xcodegen generate --quiet --spec project.yml' and commit the result." >&2
  exit 1
fi

# "${ARR[@]+"${ARR[@]}"}" keeps empty arrays safe under set -u on bash 3.2.
xcodebuild -resolvePackageDependencies \
  -project Obsidian.xcodeproj \
  -scheme Obsidian \
  ${SPM_ARGS[@]+"${SPM_ARGS[@]}"}
git diff --exit-code -- \
  Obsidian.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild test \
  -project Obsidian.xcodeproj \
  -scheme Obsidian \
  -destination 'platform=macOS' \
  ${SPM_ARGS[@]+"${SPM_ARGS[@]}"} \
  ${RESULT_ARGS[@]+"${RESULT_ARGS[@]}"} \
  CODE_SIGNING_ALLOWED=NO
