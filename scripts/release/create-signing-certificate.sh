#!/usr/bin/env bash
# Creates the OpenApps HQ release code-signing certificate: one stable,
# self-signed identity that signs every release of every app, so macOS keeps
# each app's permissions and Keychain access across updates (RELEASES.md).
#
#   scripts/release/create-signing-certificate.sh <output-dir>
#
# Run it once, on the release owner's own Mac, into a new folder that is
# never committed. It writes:
#
#   release-signing.cert.pem       the certificate (public)
#   release-signing.key.pem        its private key
#   release-signing.p12            certificate and key, password protected
#   release-signing.p12.password   that password
#   release-signing.p12.base64     the .p12 as the RELEASE_SIGNING_P12 secret
#
# Store the .p12 and its password as the RELEASE_SIGNING_P12 and
# RELEASE_SIGNING_P12_PASSWORD secrets of each app's release environment, keep
# an offline backup of the whole folder, then derive each app's pinned
# designated requirement from the certificate with
# scripts/release/designated-requirement.sh. Losing the key means every
# installed user re-grants permissions once, after a release signed with a new one.
#
# The subject is the common name alone: with an organization in it, codesign
# writes the designated requirement as `certificate root = …` instead of the
# `certificate leaf = …` form RELEASES.md pins.
#
# Nothing is imported into any keychain. Set RELEASE_SIGNING_P12_PASSWORD to
# choose the password; otherwise a random one is generated.
set -euo pipefail

OUT="${1:?usage: create-signing-certificate.sh <output-dir>}"
NAME="OpenApps HQ Release"

if [[ -e "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
    echo "error: $OUT already exists and is not empty; the certificate is created once, into a new folder" >&2
    exit 1
fi
mkdir -p "$OUT"
chmod 700 "$OUT"
umask 077

config="$OUT/.certificate.cnf"
trap 'rm -f "$config"' EXIT
cat > "$config" <<CNF
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
CNF

password="${RELEASE_SIGNING_P12_PASSWORD:-$(openssl rand -base64 33)}"

openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 7300 \
    -config "$config" -keyout "$OUT/release-signing.key.pem" -out "$OUT/release-signing.cert.pem" 2>/dev/null
chmod 644 "$OUT/release-signing.cert.pem"

# macOS `security import` reads the legacy PKCS#12 encryption; OpenSSL 3 needs
# -legacy to write it, LibreSSL writes it by default.
# (Bash 3.2 on the macOS runners treats an empty array as unset under
# `set -u`, so the flag is a plain string.)
legacy=""
if openssl version | grep -q '^OpenSSL 3'; then legacy="-legacy"; fi
printf '%s' "$password" > "$OUT/release-signing.p12.password"
# shellcheck disable=SC2086
openssl pkcs12 -export $legacy -name "$NAME" \
    -inkey "$OUT/release-signing.key.pem" -in "$OUT/release-signing.cert.pem" \
    -out "$OUT/release-signing.p12" -passout "file:$OUT/release-signing.p12.password"
base64 < "$OUT/release-signing.p12" | tr -d '\n' > "$OUT/release-signing.p12.base64"

fingerprint="$(openssl x509 -in "$OUT/release-signing.cert.pem" -outform der | shasum -a 1 | cut -d' ' -f1)"
cat <<DONE
Created "$NAME" in $OUT
  certificate SHA-1: $fingerprint

Next:
  1. Pin each app's designated requirement (public; commit it):
       scripts/release/designated-requirement.sh <bundle id> $OUT/release-signing.cert.pem \\
         > apps/<app>/release/designated-requirement.txt
  2. Set the release environment secrets:
       RELEASE_SIGNING_P12           contents of release-signing.p12.base64
       RELEASE_SIGNING_P12_PASSWORD  contents of release-signing.p12.password
  3. Back up $OUT offline, then remove it from this Mac.
DONE
