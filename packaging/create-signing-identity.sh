#!/usr/bin/env bash
# Create a self-signed code-signing identity for Phice.app.
#
# Why this exists: an ad-hoc signed bundle's designated requirement is a bare
# cdhash, which changes on every build. macOS stores that requirement alongside
# the Accessibility approval, so every rebuild silently invalidates the grant --
# and the stale entry still shows "Phice" switched on while the cursor refuses
# to move. Signing with a stable certificate makes the requirement
# `identifier "com.phice.app" and certificate leaf H"..."`, which survives
# rebuilds and, once shipped, survives updates for every user.
#
# This is NOT a Developer ID. Users downloading the app still see Gatekeeper's
# "unidentified developer" warning; only a paid Developer ID plus notarization
# removes that. What this fixes is the update path.
#
# BACK THIS UP. Once shipped, every user's Accessibility grant is bound to this
# certificate. Losing it forces all of them to re-grant. Export with:
#   security export -k login.keychain-db -t identities -f pkcs12 -o phice-id.p12
set -euo pipefail

NAME="${1:-Phice Self Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "identity '$NAME' already exists; nothing to do"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

echo "==> generating a code-signing certificate"
# codeSigning EKU is what makes `security find-identity -p codesigning` list it.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME/O=Phice" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3 defaults to AES-256-CBC/PBKDF2, which macOS's Security framework
# cannot read -- it fails with "MAC verification failed". The legacy SHA1/3DES
# algorithms are what `security import` understands.
PW="phice-transient"
openssl pkcs12 -export -out "$WORK/id.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PW" -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "==> importing into the login keychain"
# -T /usr/bin/codesign pre-authorises codesign so it does not prompt per build.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign -A

echo "==> trusting it for code signing"
# User trust domain only: no sudo, no system-wide change.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "==> allowing codesign to use the key without prompting"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
security find-identity -v -p codesigning
echo
echo "Done. Rebuild with ./packaging/build.sh to sign the bundle."
echo "You will need to grant Accessibility ONE more time after the first signed build."
