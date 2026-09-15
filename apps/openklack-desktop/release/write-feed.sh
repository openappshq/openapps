#!/usr/bin/env bash
# Writes and signs OpenKlack's update feed for a packaged release.
#
#   TAURI_SIGNING_PRIVATE_KEY=… [TAURI_SIGNING_PRIVATE_KEY_PASSWORD=…] \
#     release/write-feed.sh <version> <dist dir> <feed dir> [notes file]
#
# Reads OpenKlack-<version>.zip.sha256, .zip.sig and .app.tar.gz.sig from
# <dist dir> (release/package.sh) and writes <feed dir>/latest.json plus
# latest.json.sig, signed with the update key over the exact feed bytes. The
# feed follows RELEASES.md and carries Tauri's `platforms` for the app.
#
# Optional: BUILD (a build number, default 0), PUBLISHED_AT (RFC 3339, default
# now), DOWNLOADS (release download base, ending in `/`; default the GitHub
# release downloads of openappshq/openapps).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: write-feed.sh <version> <dist dir> <feed dir> [notes file]}"
DIST="${2:?usage: write-feed.sh <version> <dist dir> <feed dir> [notes file]}"
FEED_DIR="${3:?usage: write-feed.sh <version> <dist dir> <feed dir> [notes file]}"
NOTES_FILE="${4:-}"
: "${TAURI_SIGNING_PRIVATE_KEY:?TAURI_SIGNING_PRIVATE_KEY is not set}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
DOWNLOADS="${DOWNLOADS:-https://github.com/openappshq/openapps/releases/download/}"
[[ "$DOWNLOADS" == */ ]] || { echo "error: DOWNLOADS must end in /" >&2; exit 1; }
BUILD="${BUILD:-0}"
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "error: BUILD must be a number" >&2; exit 1; }
PUBLISHED_AT="${PUBLISHED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

sha256="$(cut -d' ' -f1 "$DIST/OpenKlack-$VERSION.zip.sha256")"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: bad digest in OpenKlack-$VERSION.zip.sha256" >&2; exit 1; }
zip_signature="$(tr -d '\n' < "$DIST/OpenKlack-$VERSION.zip.sig")"
archive_signature="$(tr -d '\n' < "$DIST/OpenKlack-$VERSION.app.tar.gz.sig")"
notes=""
if [[ -n "$NOTES_FILE" ]]; then notes="$(cat "$NOTES_FILE")"; fi
minimum_macos="$(node -p 'JSON.parse(require("fs").readFileSync("src-tauri/tauri.conf.json","utf8")).bundle.macOS.minimumSystemVersion')"

mkdir -p "$FEED_DIR"
FEED="$FEED_DIR/latest.json"
VERSION="$VERSION" BUILD="$BUILD" PUBLISHED_AT="$PUBLISHED_AT" DOWNLOADS="$DOWNLOADS" SHA256="$sha256" \
ZIP_SIGNATURE="$zip_signature" ARCHIVE_SIGNATURE="$archive_signature" NOTES="$notes" MINIMUM_MACOS="$minimum_macos" \
node --input-type=module - "$FEED" <<'JS'
import { writeFileSync } from "node:fs";
const e = process.env;
const base = `${e.DOWNLOADS}openklack-v${e.VERSION}/OpenKlack-${e.VERSION}`;
const archive = { url: `${base}.app.tar.gz`, signature: e.ARCHIVE_SIGNATURE };
const feed = {
  app: "openklack",
  channel: "stable",
  version: e.VERSION,
  build: Number(e.BUILD),
  minimum_macos: e.MINIMUM_MACOS,
  published_at: e.PUBLISHED_AT,
  pub_date: e.PUBLISHED_AT,
  notes: e.NOTES,
  url: `${base}.zip`,
  sha256: e.SHA256,
  signature: e.ZIP_SIGNATURE,
  platforms: { "darwin-aarch64": archive, "darwin-x86_64": archive },
};
writeFileSync(process.argv[2], `${JSON.stringify(feed, null, 2)}\n`);
JS

echo "==> Signing $FEED with the update key"
rm -f "$FEED.sig"
node_modules/.bin/tauri signer sign "$FEED" >/dev/null
test -f "$FEED.sig"
echo "ok: wrote $FEED and $FEED.sig"
