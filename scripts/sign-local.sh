#!/bin/zsh
# Persistent, private local signing identity. Never use an identifier-only DR.
set -eu
umask 077
SIGN_DIR="$HOME/Library/Application Support/AntonNotes-Signing"
KEYCHAIN="$SIGN_DIR/signing.keychain-db"
mkdir -p "$SIGN_DIR"
if [[ ! -f "$SIGN_DIR/ready" ]]; then
  if [[ ! -f "$KEYCHAIN" ]]; then
    openssl rand -hex 32 > "$SIGN_DIR/password"
    security create-keychain -p "$(cat "$SIGN_DIR/password")" "$KEYCHAIN"
  fi
  security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$KEYCHAIN"
  cat > "$SIGN_DIR/cert.conf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=AntonNotes Local Development
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONF
  openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 -config "$SIGN_DIR/cert.conf" -keyout "$SIGN_DIR/key.pem" -out "$SIGN_DIR/cert.pem" 2>/dev/null
  openssl pkcs12 -export -legacy -inkey "$SIGN_DIR/key.pem" -in "$SIGN_DIR/cert.pem" -out "$SIGN_DIR/identity.p12" -passout "file:$SIGN_DIR/password"
  security import "$SIGN_DIR/identity.p12" -k "$KEYCHAIN" -P "$(cat "$SIGN_DIR/password")" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$SIGN_DIR/password")" "$KEYCHAIN" >/dev/null
  rm "$SIGN_DIR/key.pem" "$SIGN_DIR/identity.p12"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$SIGN_DIR/cert.pem"
  touch "$SIGN_DIR/ready"
fi
security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$KEYCHAIN"
CERT_HASH=$(openssl x509 -in "$SIGN_DIR/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
OLD_KEYCHAINS=( ${(z)$(security list-keychains -d user)} )
OLD_KEYCHAINS=( ${(@Q)OLD_KEYCHAINS} )
trap 'security list-keychains -d user -s "${OLD_KEYCHAINS[@]}"; security lock-keychain "$KEYCHAIN"' EXIT
security list-keychains -d user -s "${OLD_KEYCHAINS[@]}" "$KEYCHAIN"
for resource in "$1/Contents/"*.bundle(N); do
  codesign --force --keychain "$KEYCHAIN" --sign "$CERT_HASH" "$resource"
done
codesign --force --keychain "$KEYCHAIN" --sign "$CERT_HASH" --requirements "=designated => identifier \"personal.anton.notes\" and certificate leaf = H\"$CERT_HASH\"" "$1"
codesign --verify --deep --strict "$1"
security lock-keychain "$KEYCHAIN"
