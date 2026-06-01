#!/usr/bin/env bash
#
# setup-signing-cert.sh - run ONCE per machine
#
# Creates a self-signed "VoiceInk-Local" Code Signing certificate in your login
# keychain so update-and-install.sh can sign local builds with a STABLE identity.
# That keeps macOS Input Monitoring / Accessibility grants across rebuilds -
# otherwise each ad-hoc rebuild gets a new cdhash and the hotkey permission
# resets. Run once, then use ./update-and-install.sh as usual.
#
# Prompts: your login password once (to trust the cert). On the first build
# afterwards, macOS asks "codesign wants to sign using key VoiceInk-Local" -
# click Always Allow.
#
set -euo pipefail

NAME="VoiceInk-Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "'$NAME' code signing identity already exists - nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = VoiceInk-Local
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> Generating self-signed code signing certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -config "$TMP/cert.cnf" -extensions v3 >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -name "$NAME" -passout pass:voiceink >/dev/null 2>&1

echo "==> Importing into login keychain (granting codesign access)..."
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P voiceink -T /usr/bin/codesign >/dev/null

echo "==> Trusting it for code signing (enter your login password if prompted)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "OK: '$NAME' is ready."
  echo "Next: ./update-and-install.sh  -- on the first build click 'Always Allow'"
  echo "when asked about key '$NAME', then grant Input Monitoring + Accessibility once."
else
  echo "'$NAME' did not register as a valid code signing identity."
  echo "Fall back to the GUI: Keychain Access > Certificate Assistant >"
  echo "Create a Certificate > Name '$NAME', Self-Signed Root, Code Signing."
  exit 1
fi
