#!/bin/zsh

set -euo pipefail

name="${1:-Markdown}"
keychain="${KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
tmpdir="$(mktemp -d)"
p12_password="${P12_PASSWORD:-markdown-local}"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

if security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -q "\"$name\""; then
  echo "Identity \"$name\" already exists in $keychain"
  exit 0
fi

cat > "$tmpdir/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no

[ dn ]
CN = $name
O = Markdown
OU = Local Code Signing

[ v3 ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req \
  -new \
  -newkey rsa:2048 \
  -nodes \
  -keyout "$tmpdir/$name.key.pem" \
  -x509 \
  -days 3650 \
  -out "$tmpdir/$name.cert.pem" \
  -config "$tmpdir/openssl.cnf" \
  -sha256 >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -inkey "$tmpdir/$name.key.pem" \
  -in "$tmpdir/$name.cert.pem" \
  -out "$tmpdir/$name.p12" \
  -passout "pass:$p12_password" >/dev/null 2>&1

# Only codesign gets unattended access to the private key (not every app, as
# -A would allow). macOS may still ask once to let codesign use the key; choose
# "Always Allow".
security import "$tmpdir/$name.p12" \
  -k "$keychain" \
  -P "$p12_password" \
  -T /usr/bin/codesign \
  -f pkcs12 >/dev/null

# Trust the self-signed certificate for code signing only, in the login
# keychain's user trust domain. Local builds are signed and run by this user,
# so system-wide (-d) trust is not needed.
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$keychain" \
  "$tmpdir/$name.cert.pem" >/dev/null

echo "Created local code-signing identity \"$name\""
security find-identity -v -p codesigning "$keychain" | grep "\"$name\""
