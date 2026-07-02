#!/usr/bin/env bash
# Builds fabulous.app from the SwiftPM package. Reproducible from a clean
# checkout: no .xcodeproj, no Xcode GUI state.
#
# Usage:
#   scripts/build.sh                 # release build, ad-hoc signed
#   CONFIG=debug scripts/build.sh    # debug build
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#       # real signing + hardened runtime (required for notarization; also
#       # keeps TCC permission grants stable across rebuilds)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BIN_DIR=".build/arm64-apple-macosx/${CONFIG}"
APP="build/fabulous.app"

echo "==> swift build (${CONFIG}, arm64)"
swift build --configuration "${CONFIG}" --arch arm64

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/fabulous" "${APP}/Contents/MacOS/fabulous"
cp Support/Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# SwiftPM resource bundles (e.g. WhisperKit's tokenizer assets) are looked up
# next to the executable or in Contents/Resources; ship them in the bundle.
for bundle in "${BIN_DIR}"/*.bundle; do
  [ -e "${bundle}" ] || continue
  cp -R "${bundle}" "${APP}/Contents/Resources/"
done

# Signing identity resolution: explicit env var wins; otherwise use the
# first code-signing identity in the keychain (scripts/make-dev-cert.sh
# creates a local "fabulous-dev" one); ad-hoc only as a last resort.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)".*$/\1/p' | head -1)
fi

if [ -n "${CODESIGN_IDENTITY}" ]; then
  echo "==> codesign (identity: ${CODESIGN_IDENTITY})"
  if [[ "${CODESIGN_IDENTITY}" == "Developer ID"* ]]; then
    # Distribution builds get the hardened runtime (notarization needs it).
    codesign --force --options runtime \
      --entitlements Support/fabulous.entitlements \
      --sign "${CODESIGN_IDENTITY}" "${APP}"
  else
    codesign --force --sign "${CODESIGN_IDENTITY}" "${APP}"
  fi
else
  echo "==> codesign (ad-hoc dev signing)"
  echo "    NOTE: TCC permissions (Mic/Accessibility) must be re-granted"
  echo "    after every rebuild with ad-hoc signing. Run"
  echo "    scripts/make-dev-cert.sh once to create a stable local identity."
  codesign --force --sign - "${APP}"
fi

echo "==> done: ${APP}"
