#!/bin/zsh
set -euo pipefail

SIGNING_IDENTITY="${MAGIC_TAP_CLICK_SIGNING_IDENTITY:-MagicTapClick Local Development}"
SIGNING_KEYCHAIN="${MAGIC_TAP_CLICK_SIGNING_KEYCHAIN:-/Users/jinoisfree/Library/Keychains/login.keychain-db}"

existing_hash="$(
    /usr/bin/security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" |
    /usr/bin/awk -v identity="$SIGNING_IDENTITY" \
        'index($0, "\"" identity "\"") { print $2; exit }'
)"
if [[ -n "$existing_hash" ]]; then
    echo "Signing identity already available: $SIGNING_IDENTITY ($existing_hash)"
    exit 0
fi

work_dir="$(mktemp -d /private/tmp/magic-tap-click-signing.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

config_path="$work_dir/openssl.cnf"
key_path="$work_dir/signing.key"
certificate_path="$work_dir/signing.cer"
bundle_path="$work_dir/signing.p12"
bundle_password="$(/usr/bin/uuidgen)"

/usr/bin/printf '%s\n' \
    '[req]' \
    'distinguished_name = subject' \
    'prompt = no' \
    'x509_extensions = code_signing' \
    '[subject]' \
    "CN = $SIGNING_IDENTITY" \
    'O = MagicTapClick' \
    '[code_signing]' \
    'basicConstraints = critical,CA:FALSE' \
    'keyUsage = critical,digitalSignature' \
    'extendedKeyUsage = codeSigning' \
    'subjectKeyIdentifier = hash' \
    'authorityKeyIdentifier = keyid:always' \
    > "$config_path"

/usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -sha256 \
    -days 3650 \
    -config "$config_path" \
    -keyout "$key_path" \
    -out "$certificate_path"

/usr/bin/openssl pkcs12 -export \
    -name "$SIGNING_IDENTITY" \
    -inkey "$key_path" \
    -in "$certificate_path" \
    -out "$bundle_path" \
    -passout "pass:$bundle_password"

/usr/bin/security import "$bundle_path" \
    -k "$SIGNING_KEYCHAIN" \
    -P "$bundle_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

/usr/bin/security add-trusted-cert \
    -r trustAsRoot \
    -p codeSign \
    -k "$SIGNING_KEYCHAIN" \
    "$certificate_path"

created_hash="$(
    /usr/bin/security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" |
    /usr/bin/awk -v identity="$SIGNING_IDENTITY" \
        'index($0, "\"" identity "\"") { print $2; exit }'
)"
if [[ -z "$created_hash" ]]; then
    echo "Signing identity was imported but is not available to codesign." >&2
    exit 1
fi

echo "Created signing identity: $SIGNING_IDENTITY ($created_hash)"
