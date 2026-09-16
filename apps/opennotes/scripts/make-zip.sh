#!/usr/bin/env bash
# Packages build/OpenNotes.app into dist/OpenNotes-<version>.zip, the
# release file (RELEASES.md): `ditto -c -k --keepParent`, which keeps the code
# signature, symlinks and extended attributes intact.
#
#   scripts/make-zip.sh [path/to/OpenNotes.app]
#
# Writes `<zip>.sha256` (`<digest>  <name>`, what shasum -c reads) next to
# the zip and prints the same line.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenNotes"
APP="${1:-build/${APP_NAME}.app}"
test -d "$APP" || { echo "error: ${APP} not found; run scripts/bundle.sh first" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
ZIP="dist/${APP_NAME}-${VERSION}.zip"

mkdir -p dist
rm -f "$ZIP"
echo "==> Creating ${ZIP}" >&2
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")
