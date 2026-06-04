#!/usr/bin/env bash
set -euo pipefail

# Creates a self-signed code-signing certificate in the user's login keychain so
# Recallyx can be signed with a stable identity across rebuilds. TCC matches
# the signed designated requirement (leaf cert hash + bundle ID), so the
# Accessibility grant survives recompiles — unlike ad-hoc signing, which TCC
# matches by cdhash and therefore invalidates on every content change.

NAME="${1:-Recallyx Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Signing identity \"$NAME\" already exists in login keychain."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Generating self-signed cert for \"$NAME\""
/usr/bin/openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" \
    >/dev/null 2>&1

echo "→ Bundling into p12"
# Use system /usr/bin/openssl (LibreSSL) — its default PBKDF is the one macOS's
# Security framework imports cleanly. OpenSSL 3.x from Homebrew defaults to
# PBES2, which fails import with "MAC verification failed".
/usr/bin/openssl pkcs12 -export \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" \
    -password pass:tmp \
    >/dev/null 2>&1

echo "→ Importing into login keychain (codesign + security may use)"
security import "$TMP/cert.p12" \
    -k "$KEYCHAIN" \
    -P tmp \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

# Allow codesign to access the private key without GUI prompts.
security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:" \
    -s -k "" "$KEYCHAIN" \
    >/dev/null 2>&1 || true

# Persist the cert PEM next to the script so the trust step is one copy-paste.
CERT_PEM_PATH="$(cd "$(dirname "$0")" && pwd)/.signing-cert.pem"
security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$CERT_PEM_PATH"

echo "✓ Created \"$NAME\" certificate in login keychain."
echo
echo "ONE MORE STEP — trust this cert for code signing (asks for keychain password):"
echo
echo "    security add-trusted-cert -p codeSign -k \"$KEYCHAIN\" \"$CERT_PEM_PATH\""
echo
echo "Then:"
echo "  ./scripts/bundle.sh           # rebuild signed with this cert"
echo "  ./scripts/install.sh          # install + relaunch"
echo "  Re-grant Accessibility ONCE — the grant now persists across rebuilds."
echo
echo "Verify it took with:  security find-identity -p codesigning -v"
