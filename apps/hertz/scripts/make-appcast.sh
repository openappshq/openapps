#!/usr/bin/env bash
# Signs a release zip with the update key and writes the signed Sparkle
# appcast that announces it (RELEASES.md, "Update feed"):
#
#   SPARKLE_ED_PRIVATE_KEY=<base64 key> scripts/make-appcast.sh dist/Hertz-1.2.3.zip
#
# The update key comes from SPARKLE_ED_PRIVATE_KEY (the secret's value) or
# SPARKLE_ED_KEY_FILE (a file holding it); it is copied only into a private
# temporary file that is removed on exit. Signing is scripts/sign-update.sh,
# byte-compatible with Sparkle's sign_update.
#
# Optional: DOWNLOAD_URL (default: the GitHub Release asset for the version),
# PUBLISHED_AT (ISO 8601 UTC, default now), NOTES, OUT (default
# dist/appcast.xml), UPDATE_PUBLIC_ED_KEY (default release/sparkle-public-key.txt)
# for the verification that ends the script.
#
# The appcast carries one item, the release, with every RELEASES.md feed field:
# app and channel (openapps:app, openapps:channel), version
# (sparkle:shortVersionString), build (sparkle:version), minimum_macos
# (sparkle:minimumSystemVersion), published_at (openapps:publishedAt and
# pubDate), notes (description), url, sha256 (openapps:sha256) and the zip's
# signature (sparkle:edSignature). The feed's own signature is then appended,
# which official builds require before trusting any field.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="${1:?usage: make-appcast.sh <zip>}"
OUT="${OUT:-dist/appcast.xml}"
test -f "$ZIP" || { echo "error: ${ZIP} not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hertz-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

KEY="$WORK/update.key"
(
    umask 077
    if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY"
    elif [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
        cp "$SPARKLE_ED_KEY_FILE" "$KEY"
    else
        echo "error: set SPARKLE_ED_PRIVATE_KEY or SPARKLE_ED_KEY_FILE" >&2
        exit 1
    fi
)

# The facts come from the app inside the zip, so the feed can only describe
# what is actually being shipped.
ditto -x -k "$ZIP" "$WORK/unzipped"
PLIST="$WORK/unzipped/Hertz.app/Contents/Info.plist"
test -f "$PLIST" || { echo "error: ${ZIP} does not contain Hertz.app" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
MINIMUM_MACOS="$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: bad version '${VERSION}'" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "error: bad build number '${BUILD}'" >&2; exit 1; }
[[ "$MINIMUM_MACOS" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "error: bad minimum macOS '${MINIMUM_MACOS}'" >&2; exit 1; }

DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/openappshq/openapps/releases/download/hertz-v${VERSION}/Hertz-${VERSION}.zip}"
PUBLISHED_AT="${PUBLISHED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
NOTES="${NOTES:-Hertz ${VERSION}. Release notes: https://github.com/openappshq/openapps/releases/tag/hertz-v${VERSION}}"
[[ "$DOWNLOAD_URL" =~ ^(https://[A-Za-z0-9.-]+|http://127\.0\.0\.1:[0-9]{1,5})/[A-Za-z0-9._~/%-]+\.zip$ ]] \
    || { echo "error: DOWNLOAD_URL must be an https URL of a .zip (or http://127.0.0.1 for local tests), got '${DOWNLOAD_URL}'" >&2; exit 1; }
[[ "$PUBLISHED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || { echo "error: PUBLISHED_AT must be ISO 8601 UTC like 2026-09-15T10:00:00Z" >&2; exit 1; }
case "$NOTES" in *']]>'*|*'<'*|*'&'*) echo "error: NOTES must be plain text without <, & or ]]>" >&2; exit 1 ;; esac
PUB_DATE="$(LC_ALL=C date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PUBLISHED_AT" '+%a, %d %b %Y %H:%M:%S +0000')"

SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
LENGTH="$(stat -f %z "$ZIP")"
SIGNATURE="$(scripts/sign-update.sh "$KEY" "$ZIP")"
[[ "$SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]] || { echo "error: sign_update returned no signature" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:openapps="https://openapps.space/xml-namespaces/releases">
    <channel>
        <title>Hertz</title>
        <link>https://openapps.space/hertz/</link>
        <description>Hertz releases</description>
        <language>en</language>
        <item>
            <title>Hertz ${VERSION}</title>
            <openapps:app>hertz</openapps:app>
            <openapps:channel>stable</openapps:channel>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:minimumSystemVersion>${MINIMUM_MACOS}</sparkle:minimumSystemVersion>
            <openapps:publishedAt>${PUBLISHED_AT}</openapps:publishedAt>
            <pubDate>${PUB_DATE}</pubDate>
            <description><![CDATA[${NOTES}]]></description>
            <openapps:sha256>${SHA256}</openapps:sha256>
            <enclosure url="${DOWNLOAD_URL}" length="${LENGTH}" type="application/octet-stream" sparkle:edSignature="${SIGNATURE}"/>
        </item>
    </channel>
</rss>
XML
scripts/sign-update.sh "$KEY" --feed "$OUT"

scripts/verify-appcast.sh "$OUT" "$ZIP"
echo "==> Wrote ${OUT} (Hertz ${VERSION}, build ${BUILD})"
