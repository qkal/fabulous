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

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> codesign (identity: ${CODESIGN_IDENTITY}, hardened runtime)"
  codesign --force --options runtime \
    --entitlements Support/fabulous.entitlements \
    --sign "${CODESIGN_IDENTITY}" "${APP}"
else
  echo "==> codesign (ad-hoc dev signing)"
  echo "    NOTE: TCC permissions (Mic/Accessibility) must be re-granted"
  echo "    after every rebuild with ad-hoc signing. Set CODESIGN_IDENTITY"
  echo "    to a stable identity to avoid this."
  codesign --force --sign - "${APP}"
fi

echo "==> done: ${APP}"
