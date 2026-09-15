#!/usr/bin/env bash
# Builds the official OpenKlack.app, signed with the release identity and
# verified against the pinned designated requirement. Meant to run inside
# scripts/release/with-signing-keychain.sh, which provides
# RELEASE_SIGNING_IDENTITY and removes the identity when this script ends.
#
#   release/build-signed.sh <version> [tauri build args...]
#
# Licensing and the updater are compiled in; the licensing variables
# (OPENKLACK_LICENSE_ENV etc.) and TAURI_SIGNING_PRIVATE_KEY come from the
# environment. Extra arguments go to `tauri build` (for example
# `--target universal-apple-darwin`); BUNDLE_DIR names where the bundle
# landed and must be set when a target changes it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: build-signed.sh <version> [tauri build args...]}"
shift
: "${RELEASE_SIGNING_IDENTITY:?run inside scripts/release/with-signing-keychain.sh}"
: "${TAURI_SIGNING_PRIVATE_KEY:?TAURI_SIGNING_PRIVATE_KEY is not set}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
BUNDLE_DIR="${BUNDLE_DIR:-src-tauri/target/release/bundle/macos}"
PINNED="release/designated-requirement.txt"
if grep -q '^NOT GENERATED' "$PINNED" release/updater-public-key.txt; then
    echo "error: the release certificate or update key has not been generated yet (RELEASES.md); refusing to build a release" >&2
    exit 1
fi

overlay="$(mktemp)"
trap 'rm -f "$overlay"' EXIT
# The version comes from the release tag, on top of release/tauri.release.json
# and the pinned update key.
node release/updater-config.mjs "$overlay" "$VERSION"

echo "==> Building OpenKlack $VERSION (signed as $RELEASE_SIGNING_IDENTITY)"
APPLE_SIGNING_IDENTITY="$RELEASE_SIGNING_IDENTITY" \
    node_modules/.bin/tauri build --config "$overlay" --bundles app --features licensing,updater "$@"

APP="$BUNDLE_DIR/OpenKlack.app"
test -d "$APP" || { echo "error: $APP was not produced" >&2; exit 1; }
echo "==> Verifying the signature and designated requirement"
../../scripts/release/verify-designated-requirement.sh "$APP" "$PINNED"
