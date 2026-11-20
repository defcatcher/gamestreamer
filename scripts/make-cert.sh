#!/bin/bash
# Creates a self-signed code-signing identity in a separate keychain inside the
# project (.signing/). It exists only so macOS keeps Screen Recording /
# Accessibility permissions across rebuilds. The login keychain and the
# keychain search list are left untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.signing"
KC="$DIR/gamestreamer.keychain-db"
KCPASS="gamestreamer"            # local signing keychain only, not a secret
NAME="GameStreamer Local Signing"

if [ -f "$KC" ]; then
  echo "Signing keychain already exists: $KC"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# System LibreSSL produces a PKCS#12 that `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:gs -name "$NAME"

# create-keychain may append itself to the search list; restore it afterwards.
SEARCH_LIST=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && SEARCH_LIST+=("$line")
done < <(security list-keychains -d user)

security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"          # never auto-lock
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P gs -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null

security list-keychains -d user -s "${SEARCH_LIST[@]}"

echo "Created signing identity \"$NAME\" in $KC"
