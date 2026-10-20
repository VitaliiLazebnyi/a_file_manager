#!/bin/bash
# Prints the signing identity of the program the UI tests drive (its SHA-1), making it first if
# there is none: a self-signed certificate "AFM UI Tests" in a keychain of its own,
# ~/Library/Keychains/afm-uitests.keychain-db, whose password is not a secret (it guards nothing
# but this certificate).
#
# An ad-hoc signature changes with every build, and macOS ties a permission (controlling Finder,
# Privacy & Security › Automation) to the signature: each build would ask again. Signed with
# this certificate, the program keeps its identity from build to build, and a permission given
# once stays. The certificate is not trusted by the system and signs nothing else.
#
# To remove it: security delete-keychain ~/Library/Keychains/afm-uitests.keychain-db
set -euo pipefail

keychain="$HOME/Library/Keychains/afm-uitests.keychain-db"
password="afm-uitests"
name="AFM UI Tests"

find_identity() {
    security find-identity -p codesigning "$keychain" 2>/dev/null |
        awk -v name="\"$name\"" 'index($0, name) { print $2; exit }'
}

if [[ ! -f "$keychain" ]]; then
    security create-keychain -p "$password" "$keychain"
    # No automatic locking: the UI tests sign whenever they run.
    security set-keychain-settings "$keychain"
fi
security unlock-keychain -p "$password" "$keychain"
# codesign finds the identity only in a keychain of the search list.
current=$(security list-keychains -d user | tr -d '"' | xargs)
if [[ " $current " != *" $keychain "* ]]; then
    # shellcheck disable=SC2086 # one keychain path per word
    security list-keychains -d user -s $current "$keychain"
fi

if [[ -z "$(find_identity)" ]]; then
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/afm-identity.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    cat >"$scratch/request.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$scratch/request.cnf" \
        -keyout "$scratch/key.pem" -out "$scratch/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$scratch/key.pem" -in "$scratch/cert.pem" \
        -out "$scratch/identity.p12" -passout pass:"$password"
    security import "$scratch/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
    # codesign may use the key without asking (no dialog for the keychain's password).
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
fi

identity=$(find_identity)
[[ -n "$identity" ]] || { echo "no signing identity \"$name\" in $keychain" >&2; exit 2; }
echo "$identity"
