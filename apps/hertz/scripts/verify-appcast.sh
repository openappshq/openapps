#!/usr/bin/env bash
# Verifies a signed appcast, and optionally the zip it announces, with the
# public update key only, the way an installed official build does:
#
#   scripts/verify-appcast.sh <appcast.xml> [zip]
#
# Checks the feed signature Sparkle's sign_update embedded (Ed25519 over the
# feed bytes before the signature comment), then the item: exactly one
# enclosure, and for a given zip its length, SHA-256 and Ed25519 signature.
# Prints `version build url sha256` on its last line.
#
# The key is UPDATE_PUBLIC_ED_KEY, else release/sparkle-public-key.txt. Needs
# OpenSSL 3 (for Ed25519): `openssl` on PATH, Homebrew's openssl@3, or
# OPENSSL; runs on macOS and Linux, so the publish jobs can check what they
# fetch.
set -euo pipefail
cd "$(dirname "$0")/.."

FEED="${1:?usage: verify-appcast.sh <appcast.xml> [zip]}"
ZIP="${2:-}"
PUBLIC_KEY="${UPDATE_PUBLIC_ED_KEY:-$(head -n 1 release/sparkle-public-key.txt)}"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "error: no update public key (release/sparkle-public-key.txt is not generated?)" >&2; exit 1; }
# macOS ships LibreSSL as `openssl`, which has no Ed25519 verification; look
# for Homebrew's OpenSSL 3 when OPENSSL is not given.
if [[ -z "${OPENSSL:-}" ]]; then
    for candidate in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if "$candidate" version 2>/dev/null | grep -q '^OpenSSL 3'; then OPENSSL="$candidate"; break; fi
    done
    OPENSSL="${OPENSSL:-openssl}"
fi
"$OPENSSL" version | grep -q '^OpenSSL 3' || { echo "error: ${OPENSSL} is not OpenSSL 3 (brew install openssl@3, or set OPENSSL)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hertz-verify-feed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Ed25519 SubjectPublicKeyInfo: the fixed 12-byte header, then the raw key.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$PUBLIC_KEY" | "$OPENSSL" base64 -d -A; } > "$WORK/key.der"
"$OPENSSL" pkey -pubin -inform DER -in "$WORK/key.der" -out "$WORK/key.pem"

verify_ed25519() { # <data file> <base64 signature>
    printf '%s' "$2" | "$OPENSSL" base64 -d -A > "$WORK/sig.bin"
    "$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/key.pem" -rawin -in "$1" -sigfile "$WORK/sig.bin" >/dev/null 2>&1
}

# sign_update appends: <!-- sparkle-signatures:\nedSignature: <sig>\nlength: <n>\n-->
feed_sig="$(sed -n 's/^edSignature: \([A-Za-z0-9+/=]*\)$/\1/p' "$FEED")"
feed_len="$(sed -n 's/^length: \([0-9]*\)$/\1/p' "$FEED")"
[[ -n "$feed_sig" && -n "$feed_len" ]] || { echo "FAIL: ${FEED} carries no feed signature" >&2; exit 1; }
[[ "$(grep -c '^edSignature: ' "$FEED")" == 1 ]] || { echo "FAIL: ${FEED} carries more than one feed signature" >&2; exit 1; }
head -c "$feed_len" "$FEED" > "$WORK/signed.xml"
# Everything after the signed bytes must be the signature comment itself.
tail -c "+$((feed_len + 1))" "$FEED" > "$WORK/trailer"
grep -q 'sparkle-signatures:' "$WORK/trailer" || { echo "FAIL: the feed signature does not cover the feed" >&2; exit 1; }
if grep -q '<item>\|<enclosure' "$WORK/trailer"; then echo "FAIL: content after the signed part of the feed" >&2; exit 1; fi
verify_ed25519 "$WORK/signed.xml" "$feed_sig" || { echo "FAIL: feed signature does not verify with the update key" >&2; exit 1; }
echo "ok: feed signature" >&2

field() { sed -n "s|.*<$1>\\([^<]*\\)</$1>.*|\\1|p" "$WORK/signed.xml"; }
attr() { sed -n "s|.*<enclosure [^>]*$1=\"\\([^\"]*\\)\".*|\\1|p" "$WORK/signed.xml"; }
[[ "$(grep -c '<item>' "$WORK/signed.xml")" == 1 && "$(grep -c '<enclosure ' "$WORK/signed.xml")" == 1 ]] \
    || { echo "FAIL: the feed must announce exactly one release" >&2; exit 1; }
version="$(field sparkle:shortVersionString)"
build="$(field sparkle:version)"
url="$(attr url)"
length="$(attr length)"
signature="$(attr sparkle:edSignature)"
sha256="$(field openapps:sha256)"
[[ "$(field openapps:app)" == hertz && "$(field openapps:channel)" == stable ]] || { echo "FAIL: not a Hertz stable feed" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ && "$sha256" =~ ^[0-9a-f]{64}$ && -n "$url" && -n "$signature" ]] \
    || { echo "FAIL: the feed item is missing fields" >&2; exit 1; }

if [[ -n "$ZIP" ]]; then
    [[ "$(wc -c < "$ZIP" | tr -d ' ')" == "$length" ]] || { echo "FAIL: ${ZIP} is not the announced length ${length}" >&2; exit 1; }
    actual="$(shasum -a 256 "$ZIP" 2>/dev/null | cut -d' ' -f1 || sha256sum "$ZIP" | cut -d' ' -f1)"
    [[ "$actual" == "$sha256" ]] || { echo "FAIL: ${ZIP} has SHA-256 ${actual}, the feed announces ${sha256}" >&2; exit 1; }
    verify_ed25519 "$ZIP" "$signature" || { echo "FAIL: ${ZIP} signature does not verify with the update key" >&2; exit 1; }
    echo "ok: zip length, SHA-256 and signature" >&2
fi
echo "$version $build $url $sha256"
