#!/usr/bin/env bash
# Checks what users actually get after a release (RELEASES.md, "Verify
# live"): the public zip on GitHub and the feed the website serves.
#
#   scripts/verify-live.sh <version> <expected sha256>
#
# Downloads the release's zip and checks its digest, then waits up to
# WAIT_SECONDS (default 1500, the website deploy after the feed commit) for
# https://openapps.space/updates/opennotes/appcast.xml to announce the
# version, and verifies the feed's signature and its claims about the zip
# with the committed public key. Runs on macOS and Linux (OpenSSL 3 as
# `openssl`, or OPENSSL).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: verify-live.sh <version> <expected sha256>}"
EXPECTED_SHA256="${2:?usage: verify-live.sh <version> <expected sha256>}"
WAIT_SECONDS="${WAIT_SECONDS:-1500}"
FEED_URL="https://openapps.space/updates/opennotes/appcast.xml"
ZIP_URL="https://github.com/openappshq/openapps/releases/download/opennotes-v${VERSION}/OpenNotes-${VERSION}.zip"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: expected sha256 must be 64 lowercase hex digits" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/opennotes-live.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha256_of() {
    if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

echo "==> Downloading ${ZIP_URL}"
curl -fsSL --retry 5 --retry-delay 10 -o "$WORK/OpenNotes-${VERSION}.zip" "$ZIP_URL"
actual="$(sha256_of "$WORK/OpenNotes-${VERSION}.zip")"
[[ "$actual" == "$EXPECTED_SHA256" ]] || { echo "error: the public zip has SHA-256 ${actual}, expected ${EXPECTED_SHA256}" >&2; exit 1; }
echo "ok: public zip ${EXPECTED_SHA256}"

echo "==> Waiting for ${FEED_URL} to announce ${VERSION}"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
announced=""
while :; do
    # Cache-busting query: the feed is cached for five minutes at the edge.
    if curl -fsSL -H 'Cache-Control: no-cache' -o "$WORK/appcast.xml" "${FEED_URL}?t=$(date +%s)" \
        && grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$WORK/appcast.xml"; then
        announced=1
        break
    fi
    if (( $(date +%s) >= deadline )); then break; fi
    sleep 30
done
[[ -n "$announced" ]] || { echo "error: the live feed still does not announce ${VERSION} after ${WAIT_SECONDS}s" >&2; exit 1; }

read -r version _ url sha256 < <(scripts/verify-appcast.sh "$WORK/appcast.xml" "$WORK/OpenNotes-${VERSION}.zip")
if [[ "$version" != "$VERSION" || "$sha256" != "$EXPECTED_SHA256" || "$url" != "$ZIP_URL" ]]; then
    echo "error: the live feed announces ${version} ${sha256} at ${url}, not ${VERSION} ${EXPECTED_SHA256} at ${ZIP_URL}" >&2
    exit 1
fi
echo "ok: live feed announces ${VERSION} at ${ZIP_URL}, signed, digest matches"
