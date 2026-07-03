#!/usr/bin/env bash
# Packages build/fabulous.app into a distributable dmg with a styled
# window (background, positioned icons, /Applications drop link).
#
# Usage: scripts/make-dmg.sh <version>       # e.g. 0.1.0
# Requires: build/fabulous.app (scripts/build.sh), create-dmg (Homebrew).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-dmg.sh <version>}"
APP="build/fabulous.app"
STAGE="build/dmg-stage"
DMG="build/fabulous-${VERSION}.dmg"

[ -d "${APP}" ] || { echo "error: ${APP} missing — run scripts/build.sh first" >&2; exit 1; }
command -v create-dmg >/dev/null 2>&1 \
  || { echo "error: create-dmg not found — brew install create-dmg" >&2; exit 1; }

# create-dmg takes a source FOLDER; stage the app alone so nothing else
# from build/ leaks into the image.
rm -rf "${STAGE}" "${DMG}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"

ARGS=(
  --volname "fabulous ${VERSION}"
  --background "Support/dmg-background@2x.png"
  --window-size 600 400
  --icon-size 128
  --icon "fabulous.app" 150 200
  --app-drop-link 450 200
)
# Finder scripting is unreliable on headless CI runners; create-dmg's
# --skip-jenkins skips the AppleScript-driven Finder styling there.
[ -n "${CI:-}" ] && ARGS+=(--skip-jenkins)

# create-dmg occasionally trips over Finder/AppleScript timing; retry once.
if ! create-dmg "${ARGS[@]}" "${DMG}" "${STAGE}"; then
  echo "==> create-dmg failed, retrying once"
  rm -f "${DMG}"
  create-dmg "${ARGS[@]}" "${DMG}" "${STAGE}"
fi

rm -rf "${STAGE}"
echo "==> done: ${DMG}"
