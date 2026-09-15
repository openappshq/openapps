#!/usr/bin/env bash
# Runs one command with the release signing identity available, and removes
# the identity again before returning, whatever the command does.
#
#   RELEASE_SIGNING_P12=<base64 .p12> RELEASE_SIGNING_P12_PASSWORD=<password> \
#     scripts/release/with-signing-keychain.sh <command> [args...]
#
# (RELEASE_SIGNING_P12_FILE=<path to .p12> may be given instead of the base64.)
#
# The .p12 is imported into a new temporary keychain with a random password;
# no existing keychain is opened or changed. codesign only finds an identity
# in a keychain on the user's search list, so the temporary keychain is added
# to the front of that list for the duration of the command, and afterwards
# that entry is removed again and the keychain file is deleted. Other entries
# are left alone, except ones whose keychain file no longer exists: those are
# leftovers of a temporary keychain (this script's or another tool's, when
# two runs overlap on one Mac) and are dropped too.
#
# The command sees RELEASE_SIGNING_IDENTITY (the certificate's SHA-1, for
# `codesign --sign`) and RELEASE_SIGNING_KEYCHAIN (for `codesign --keychain`).
# The script fails if the identity can still be found after cleanup.
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: with-signing-keychain.sh <command> [args...]" >&2
    exit 2
fi
: "${RELEASE_SIGNING_P12_PASSWORD?RELEASE_SIGNING_P12_PASSWORD is not set}"
if [[ -z "${RELEASE_SIGNING_P12_FILE:-}" && -z "${RELEASE_SIGNING_P12:-}" ]]; then
    echo "error: set RELEASE_SIGNING_P12 (base64) or RELEASE_SIGNING_P12_FILE" >&2
    exit 1
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/signing.XXXXXX")"
work="$(cd -P "$work" && pwd)"
keychain="$work/release-signing.keychain-db"
identity=""

keychain_entries() {
    local line
    security list-keychains -d user | while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%\"}"
        printf '%s\n' "${line#\"}"
    done
}

cleanup() {
    local status=$? remaining=() entry
    trap - EXIT INT TERM
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == "$keychain" || ! -e "$entry" ]] || remaining+=("$entry")
    done < <(keychain_entries)
    security list-keychains -d user -s "${remaining[@]}" || status=1
    if [[ -e "$keychain" ]]; then
        security delete-keychain "$keychain" || status=1
    fi
    rm -rf "$work"
    if [[ -n "$identity" ]]; then
        local identities
        identities="$(security find-identity -p codesigning 2>/dev/null || true)"
        if grep -Fq "$identity" <<< "$identities"; then
            echo "error: the signing identity is still available after cleanup" >&2
            status=1
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

umask 077
p12="$work/release-signing.p12"
if [[ -n "${RELEASE_SIGNING_P12_FILE:-}" ]]; then
    cp "$RELEASE_SIGNING_P12_FILE" "$p12"
else
    printf '%s' "$RELEASE_SIGNING_P12" | base64 --decode > "$p12"
fi
keychain_password="$(openssl rand -hex 24)"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -P "$RELEASE_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null

found="$(security find-identity -p codesigning "$keychain")"
hashes="$(sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) "OpenApps HQ Release".*/\1/p' <<< "$found" | sort -u)"
if [[ "$(grep -c . <<< "$hashes")" != 1 ]]; then
    echo "error: the .p12 must hold exactly one \"OpenApps HQ Release\" code-signing identity" >&2
    printf '%s\n' "$found" >&2
    exit 1
fi
identity="$hashes"

current=()
while IFS= read -r entry; do
    [[ -z "$entry" ]] || current+=("$entry")
done < <(keychain_entries)
security list-keychains -d user -s "$keychain" "${current[@]}"

RELEASE_SIGNING_IDENTITY="$identity" RELEASE_SIGNING_KEYCHAIN="$keychain" "$@"
