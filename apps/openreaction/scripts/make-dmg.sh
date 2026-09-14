#!/usr/bin/env bash
# Packages build/OpenReaction.app into dist/OpenReaction-<version>.dmg: the
# app plus an Applications link, compressed, signed with the same identity as
# the app (ad-hoc when APPLE_SIGNING_IDENTITY is unset).
#
#   scripts/make-dmg.sh [path/to/OpenReaction.app]
#
# Prints the DMG path on its last line. Notarize and staple it afterwards with
# scripts/notarize.sh; the checksum is taken after stapling, since stapling
# changes the file.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenReaction"
APP="${1:-build/${APP_NAME}.app}"
IDENTITY="${APPLE_SIGNING_IDENTITY:--}"

test -d "$APP" || { echo "error: ${APP} not found; run scripts/bundle.sh first" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/openreaction-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p dist
rm -f "$DMG"

echo "==> Staging ${APP} for ${DMG}"
# ditto keeps extended attributes, resource forks and the code signature intact.
ditto "$APP" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating ${DMG}"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"

echo "==> Signing DMG with identity: ${IDENTITY}"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DMG"
else
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
codesign --verify --verbose=2 "$DMG"

echo "==> Done: ${DMG}"
