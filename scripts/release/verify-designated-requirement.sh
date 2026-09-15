#!/usr/bin/env bash
# Fails unless an app's signature is valid, uses the hardened runtime, and
# has exactly the designated requirement pinned for it.
#
#   scripts/release/verify-designated-requirement.sh <App.app> <designated-requirement.txt>
#
# The pinned file is written by designated-requirement.sh. A file that still
# holds the NOT GENERATED marker fails: no release is signed before the
# certificate exists.
set -euo pipefail

APP="${1:?usage: verify-designated-requirement.sh <App.app> <designated-requirement.txt>}"
PINNED_FILE="${2:?usage: verify-designated-requirement.sh <App.app> <designated-requirement.txt>}"

pinned="$(tr -d '\r' < "$PINNED_FILE" | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true)"
case "$pinned" in
    "NOT GENERATED"*|"")
        echo "error: $PINNED_FILE has no pinned requirement yet; generate the release certificate first (RELEASES.md)" >&2
        exit 1 ;;
esac
if [[ "$(grep -c . <<< "$pinned")" != 1 ]]; then
    echo "error: $PINNED_FILE must hold exactly one requirement line" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP"

details="$(codesign --display --verbose=2 "$APP" 2>&1)"
if ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' <<< "$details"; then
    echo "error: $APP is not signed with the hardened runtime" >&2
    printf '%s\n' "$details" >&2
    exit 1
fi

requirements="$(codesign --display --requirements - "$APP" 2>&1)"
actual="$(sed -n 's/^designated => //p' <<< "$requirements")"
if [[ "$actual" != "$pinned" ]]; then
    echo "error: $APP has the designated requirement" >&2
    echo "  $actual" >&2
    echo "but $PINNED_FILE pins" >&2
    echo "  $pinned" >&2
    echo "Installed copies would lose their permissions and Keychain access; refusing." >&2
    exit 1
fi
codesign --verify --strict "-R=$pinned" "$APP"
echo "ok: $APP satisfies $pinned"
