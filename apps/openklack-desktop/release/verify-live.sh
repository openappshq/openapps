#!/usr/bin/env bash
# Checks a published release the way an installed app and the cask see it:
# fetches the public zip and the live feed with its signature, then checks
# the zip's digest, the feed signature, and that the feed names this version
# and this zip.
#
#   release/verify-live.sh <version> <expected zip sha256> [public key file]
#
# FEED_URL (default https://openapps.space/updates/openklack/latest.json) and
# DOWNLOADS (default the GitHub release downloads, ending in `/`) can point at
# a local server. The feed is polled for up to WAIT_SECONDS (default 0) until
# it names the version, for the minutes between a feed commit and its deploy.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: verify-live.sh <version> <expected zip sha256> [public key file]}"
EXPECTED_SHA256="${2:?usage: verify-live.sh <version> <expected zip sha256> [public key file]}"
KEY="${3:-release/updater-public-key.txt}"
FEED_URL="${FEED_URL:-https://openapps.space/updates/openklack/latest.json}"
DOWNLOADS="${DOWNLOADS:-https://github.com/openappshq/openapps/releases/download/}"
WAIT_SECONDS="${WAIT_SECONDS:-0}"
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: expected sha256 must be 64 lowercase hex digits" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fetch() {
    curl --fail --silent --show-error --location --max-redirs 3 --max-time 120 --output "$2" "$1"
}

zip_url="${DOWNLOADS}openklack-v${VERSION}/OpenKlack-${VERSION}.zip"
echo "==> Fetching $zip_url"
fetch "$zip_url" "$work/OpenKlack.zip"
actual="$(shasum -a 256 "$work/OpenKlack.zip" | cut -d' ' -f1)"
if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    echo "error: the public zip has SHA-256 $actual, expected $EXPECTED_SHA256" >&2
    exit 1
fi
echo "ok: zip digest $actual"

echo "==> Fetching $FEED_URL"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
    if fetch "$FEED_URL?$(date +%s)" "$work/latest.json" \
        && [[ "$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version' "$work/latest.json" 2>/dev/null)" == "$VERSION" ]]; then
        break
    fi
    if (( $(date +%s) >= deadline )); then
        echo "error: $FEED_URL does not name $VERSION" >&2
        exit 1
    fi
    sleep 15
done
fetch "$FEED_URL.sig?$(date +%s)" "$work/latest.json.sig"
node release/verify-update-signature.mjs "$work/latest.json" "$work/latest.json.sig" "$KEY"

FEED="$work/latest.json" VERSION="$VERSION" ZIP_URL="$zip_url" SHA256="$EXPECTED_SHA256" node --input-type=module - <<'JS'
import { readFileSync } from "node:fs";
const e = process.env;
const feed = JSON.parse(readFileSync(e.FEED, "utf8"));
const problems = [];
if (feed.app !== "openklack") problems.push(`app is ${feed.app}`);
if (feed.channel !== "stable") problems.push(`channel is ${feed.channel}`);
if (feed.version !== e.VERSION) problems.push(`version is ${feed.version}`);
if (feed.url !== e.ZIP_URL) problems.push(`url is ${feed.url}`);
if (feed.sha256 !== e.SHA256) problems.push(`sha256 is ${feed.sha256}`);
if (!feed.platforms?.["darwin-aarch64"]?.signature) problems.push("no darwin-aarch64 archive");
if (problems.length) {
  console.error(`error: the live feed is wrong: ${problems.join("; ")}`);
  process.exit(1);
}
console.log(`ok: the live feed names ${feed.version} at ${feed.url}`);
JS
