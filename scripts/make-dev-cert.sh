#!/usr/bin/env bash
# One-time setup: creates a local self-signed code-signing certificate so
# dev builds keep a stable signature — TCC permission grants (Microphone,
# Accessibility) then survive rebuilds.
#
# The identity lives in its own keychain (fabulous-dev.keychain-db) with a
# known password, so signing never triggers an interactive Keychain prompt.
# Nothing here touches the login keychain or requires admin rights.
#
# Idempotent: re-running replaces the keychain and certificate.
set -euo pipefail

CERT_NAME="fabulous-dev"
KEYCHAIN="$HOME/Library/Keychains/fabulous-dev.keychain-db"
KEYCHAIN_PASS="fabulous-dev-local"   # local-only keychain; not a secret
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "==> generating self-signed code-signing certificate (${CERT_NAME})"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "${WORKDIR}/key.pem" -out "${WORKDIR}/cert.pem" \
  -subj "/CN=${CERT_NAME}" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# -legacy: OpenSSL 3.x defaults to PBKDF2/AES containers that macOS's
# `security import` can't read; the legacy provider emits 3DES/RC2 it can.
openssl pkcs12 -export -legacy -name "${CERT_NAME}" \
  -inkey "${WORKDIR}/key.pem" -in "${WORKDIR}/cert.pem" \
  -out "${WORKDIR}/${CERT_NAME}.p12" -passout "pass:${KEYCHAIN_PASS}"

echo "==> creating dedicated keychain"
security delete-keychain "${KEYCHAIN}" 2>/dev/null || true
security create-keychain -p "${KEYCHAIN_PASS}" "${KEYCHAIN}"
security set-keychain-settings "${KEYCHAIN}"   # never auto-lock
security unlock-keychain -p "${KEYCHAIN_PASS}" "${KEYCHAIN}"

security import "${WORKDIR}/${CERT_NAME}.p12" \
  -k "${KEYCHAIN}" -P "${KEYCHAIN_PASS}" -T /usr/bin/codesign

# Pre-authorize codesign for the private key (avoids the per-build prompt).
security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
  -s -k "${KEYCHAIN_PASS}" "${KEYCHAIN}" >/dev/null

# Add to the user's keychain search list (keeping existing entries).
EXISTING=$(security list-keychains -d user | tr -d '" ' | grep -v "fabulous-dev" || true)
# shellcheck disable=SC2086
security list-keychains -d user -s ${EXISTING} "${KEYCHAIN}"

echo "==> done. verify with: security find-identity -p codesigning | grep ${CERT_NAME}"
echo "    scripts/build.sh will now pick it up automatically."
