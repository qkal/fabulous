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
trap 'rm -rf "${STAGE}"' EXIT

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
# --skip-jenkins skips create-dmg's ENTIRE AppleScript-driven Finder styling
# pass (background image, window size, icon positions) — not just the
# flaky bits. Always attempt the styled dmg first, even on CI: GitHub's
# macOS runners have a GUI session, so Finder scripting usually works
# there too. Only fall back to --skip-jenkins on a CI retry, accepting a
# bare-but-functional dmg over a failed release; locally the retry stays
# styled so a real failure surfaces instead of silently degrading.
if ! create-dmg "${ARGS[@]}" "${DMG}" "${STAGE}"; then
  echo "==> create-dmg failed, retrying once"
  # Re-stage from scratch so the retry starts from the same clean state
  # as the first attempt.
  rm -f "${DMG}"
  rm -rf "${STAGE}"
  mkdir -p "${STAGE}"
  cp -R "${APP}" "${STAGE}/"
  RETRY_ARGS=("${ARGS[@]}")
  [ -n "${CI:-}" ] && RETRY_ARGS+=(--skip-jenkins)
  create-dmg "${RETRY_ARGS[@]}" "${DMG}" "${STAGE}"
fi

echo "==> done: ${DMG}"
