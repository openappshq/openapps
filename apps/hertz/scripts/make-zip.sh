#!/usr/bin/env bash
# Packages build/Hertz.app into dist/Hertz-<version>.zip, the
# release file (RELEASES.md): `ditto -c -k --keepParent`, which keeps the code
# signature, symlinks and extended attributes intact.
#
#   scripts/make-zip.sh [path/to/Hertz.app]
#
# Prints the zip's SHA-256 and path on its last line: `<digest>  <path>`.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Hertz"
APP="${1:-build/${APP_NAME}.app}"
test -d "$APP" || { echo "error: ${APP} not found; run scripts/bundle.sh first" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
ZIP="dist/${APP_NAME}-${VERSION}.zip"

mkdir -p dist
rm -f "$ZIP"
echo "==> Creating ${ZIP}" >&2
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
