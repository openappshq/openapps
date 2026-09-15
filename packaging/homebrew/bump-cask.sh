#!/usr/bin/env bash
# Sets a cask's version and sha256 to a published release.
#
#   packaging/homebrew/bump-cask.sh <cask.rb> <version> <sha256>
#
# Refuses a version lower than the cask's current one (Homebrew users never
# downgrade), and does nothing when the cask already names this release. The
# sha256 is the digest the release job verified, never one recomputed from a
# download.
set -euo pipefail

CASK="${1:?usage: bump-cask.sh <cask.rb> <version> <sha256>}"
VERSION="${2:?usage: bump-cask.sh <cask.rb> <version> <sha256>}"
SHA256="${3:?usage: bump-cask.sh <cask.rb> <version> <sha256>}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: sha256 must be 64 lowercase hex digits" >&2; exit 1; }

version_lines="$(grep -cE '^  version "[^"]+"$' "$CASK" || true)"
sha_lines="$(grep -cE '^  sha256 "[^"]+"$' "$CASK" || true)"
if [[ "$version_lines" != 1 || "$sha_lines" != 1 ]]; then
    echo "error: $CASK must have exactly one top-level version and one sha256 line" >&2
    exit 1
fi
current="$(sed -nE 's/^  version "([^"]+)"$/\1/p' "$CASK")"
current_sha="$(sed -nE 's/^  sha256 "([^"]+)"$/\1/p' "$CASK")"
if [[ "$current" == "$VERSION" ]]; then
    if [[ "$current_sha" == "$SHA256" ]]; then
        echo "ok: $CASK already names $VERSION"
        exit 0
    fi
    echo "error: $CASK already names $VERSION with a different sha256; a release is never rewritten" >&2
    exit 1
fi
if [[ "$(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
    echo "error: $CASK is at $current, newer than $VERSION" >&2
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -E -e "s/^  version \"[^\"]+\"$/  version \"$VERSION\"/" -e "s/^  sha256 \"[^\"]+\"$/  sha256 \"$SHA256\"/" "$CASK" > "$tmp"
cat "$tmp" > "$CASK"
echo "ok: $CASK $current -> $VERSION"
