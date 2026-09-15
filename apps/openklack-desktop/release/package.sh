#!/usr/bin/env bash
# Packages a built, signed OpenKlack.app for release: the zip the cask
# installs, the update archive the app installs, and their update signatures.
#
#   TAURI_SIGNING_PRIVATE_KEY=… [TAURI_SIGNING_PRIVATE_KEY_PASSWORD=…] \
#     release/package.sh <bundle dir> <version> <dist dir> [public key file]
#
# <bundle dir> is Tauri's bundle/macos output, holding OpenKlack.app and the
# OpenKlack.app.tar.gz plus .sig that createUpdaterArtifacts wrote. Writes to
# <dist dir>:
#
#   OpenKlack-<version>.zip             ditto -c -k --keepParent of the app
#   OpenKlack-<version>.zip.sig         update-key signature of the zip
#   OpenKlack-<version>.zip.sha256      its SHA-256, in shasum format
#   OpenKlack-<version>.app.tar.gz      the update archive
#   OpenKlack-<version>.app.tar.gz.sig  its update-key signature
#
# Every signature is verified against the public key before the script
# succeeds (release/updater-public-key.txt unless a file is given).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="${1:?usage: package.sh <bundle dir> <version> <dist dir> [public key file]}"
VERSION="${2:?usage: package.sh <bundle dir> <version> <dist dir> [public key file]}"
DIST="${3:?usage: package.sh <bundle dir> <version> <dist dir> [public key file]}"
KEY="${4:-release/updater-public-key.txt}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
: "${TAURI_SIGNING_PRIVATE_KEY:?TAURI_SIGNING_PRIVATE_KEY is not set}"
APP="$BUNDLE/OpenKlack.app"
test -d "$APP" || { echo "error: $APP not found" >&2; exit 1; }
test -f "$BUNDLE/OpenKlack.app.tar.gz" -a -f "$BUNDLE/OpenKlack.app.tar.gz.sig" \
    || { echo "error: $BUNDLE has no update archive; build with release/tauri.release.json" >&2; exit 1; }

plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$plist_version" != "$VERSION" ]]; then
    echo "error: $APP is version $plist_version, not $VERSION" >&2
    exit 1
fi

mkdir -p "$DIST"
ZIP="$DIST/OpenKlack-$VERSION.zip"
ARCHIVE="$DIST/OpenKlack-$VERSION.app.tar.gz"
rm -f "$ZIP" "$ZIP.sig" "$ZIP.sha256" "$ARCHIVE" "$ARCHIVE.sig"

echo "==> Zipping $APP"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$BUNDLE/OpenKlack.app.tar.gz" "$ARCHIVE"
cp "$BUNDLE/OpenKlack.app.tar.gz.sig" "$ARCHIVE.sig"

echo "==> Signing the zip with the update key"
# `tauri signer sign` writes <file>.sig next to the file.
node_modules/.bin/tauri signer sign "$ZIP" >/dev/null
test -f "$ZIP.sig"

max=$((128 * 1024 * 1024))
for file in "$ZIP" "$ARCHIVE"; do
    size="$(stat -f %z "$file")"
    if (( size == 0 || size > max )); then
        echo "error: $file is $size bytes; the app downloads at most $max" >&2
        exit 1
    fi
done

echo "==> Verifying update signatures"
node release/verify-update-signature.mjs "$ZIP" "$ZIP.sig" "$KEY"
node release/verify-update-signature.mjs "$ARCHIVE" "$ARCHIVE.sig" "$KEY"

(cd "$DIST" && shasum -a 256 "OpenKlack-$VERSION.zip" | tee "OpenKlack-$VERSION.zip.sha256")
