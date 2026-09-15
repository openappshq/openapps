#!/usr/bin/env bash
# Prints the designated requirement codesign gives an app with this bundle
# identifier when it is signed with this certificate:
#
#   identifier "<bundle id>" and certificate leaf = H"<certificate SHA-1>"
#
#   scripts/release/designated-requirement.sh <bundle id> <certificate.pem>
#
# The output is public and is committed as apps/<app>/release/designated-requirement.txt;
# verify-designated-requirement.sh fails a release whose signature does not
# produce exactly that requirement.
set -euo pipefail

BUNDLE_ID="${1:?usage: designated-requirement.sh <bundle id> <certificate.pem>}"
CERTIFICATE="${2:?usage: designated-requirement.sh <bundle id> <certificate.pem>}"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "error: '$BUNDLE_ID' is not a bundle identifier" >&2
    exit 1
fi
fingerprint="$(openssl x509 -in "$CERTIFICATE" -outform der | shasum -a 1 | cut -d' ' -f1)"
printf 'identifier "%s" and certificate leaf = H"%s"\n' "$BUNDLE_ID" "$fingerprint"
