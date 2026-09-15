#!/usr/bin/env bash
# Creates OpenKlack's update key: the Tauri updater key pair that signs every
# update archive, zip and feed, and whose public half official builds pin.
#
#   apps/openklack-desktop/release/create-update-key.sh <output-dir>
#
# Run it once, on the release owner's own Mac. It asks for a password, writes
# the private key to <output-dir>/openklack-update.key (never committed), and
# copies the public key into release/updater-public-key.txt for committing.
# Store the private key as TAURI_SIGNING_PRIVATE_KEY and its password as
# TAURI_SIGNING_PRIVATE_KEY_PASSWORD in the openklack-release environment, and
# back it up offline: without it no installed copy can ever update again.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: create-update-key.sh <output-dir>}"
if [[ -e "$OUT/openklack-update.key" ]]; then
    echo "error: $OUT/openklack-update.key already exists; the update key is created once" >&2
    exit 1
fi
if ! grep -q '^NOT GENERATED' release/updater-public-key.txt; then
    echo "error: release/updater-public-key.txt already pins a key; replacing it strands every installed copy" >&2
    exit 1
fi
mkdir -p "$OUT"
chmod 700 "$OUT"
node_modules/.bin/tauri signer generate --write-keys "$OUT/openklack-update.key"
tr -d '\n' < "$OUT/openklack-update.key.pub" > release/updater-public-key.txt
echo
echo "Pinned the public key in apps/openklack-desktop/release/updater-public-key.txt; commit it."
