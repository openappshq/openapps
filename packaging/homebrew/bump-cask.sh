#!/usr/bin/env bash
# Sets a cask's version and sha256 to a published release.
#
#   packaging/homebrew/bump-cask.sh <cask.rb> <version> <sha256> [template.rb]
#
# Refuses a version lower than the cask's current one (Homebrew users never
# downgrade), and does nothing when the cask already names this release. A
# cask that names no release yet (the template's 0.0.0 with an all-zero
# digest) takes any version. The sha256 is the digest the release job
# verified, never one recomputed from a download.
#
# With the app's cask template as the fourth argument, the cask's `desc`
# line is set to the template's, so the one line of copy the tap shows
# (`brew info`, `brew search`) follows the repository instead of drifting
# from the first release it was copied at. That happens even when the cask
# already names the release, so a re-run carries a copy change alone.
set -euo pipefail

usage="usage: bump-cask.sh <cask.rb> <version> <sha256> [template.rb]"
CASK="${1:?$usage}"
VERSION="${2:?$usage}"
SHA256="${3:?$usage}"
TEMPLATE="${4:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: sha256 must be 64 lowercase hex digits" >&2; exit 1; }

version_lines="$(grep -cE '^  version "[^"]+"$' "$CASK" || true)"
sha_lines="$(grep -cE '^  sha256 "[^"]+"$' "$CASK" || true)"
if [[ "$version_lines" != 1 || "$sha_lines" != 1 ]]; then
    echo "error: $CASK must have exactly one top-level version and one sha256 line" >&2
    exit 1
fi

# The template's desc, when asked for: exactly one `desc "…"` line in each
# file, so the swap can only ever touch that line.
desc_line=""
if [[ -n "$TEMPLATE" ]]; then
    [[ -f "$TEMPLATE" ]] || { echo "error: template $TEMPLATE not found" >&2; exit 1; }
    template_desc_lines="$(grep -cE '^  desc "[^"]+"$' "$TEMPLATE" || true)"
    cask_desc_lines="$(grep -cE '^  desc "[^"]+"$' "$CASK" || true)"
    if [[ "$template_desc_lines" != 1 || "$cask_desc_lines" != 1 ]]; then
        echo "error: $TEMPLATE and $CASK must each have exactly one desc line" >&2
        exit 1
    fi
    desc_line="$(grep -E '^  desc "[^"]+"$' "$TEMPLATE")"
    if [[ "$desc_line" == *[\\\&\|]* ]]; then
        echo "error: the template's desc must not contain a backslash, & or |" >&2
        exit 1
    fi
fi

# Rewrites the desc line from the template, when there is one. A no-op
# when the cask already carries it.
sync_desc() {
    [[ -n "$desc_line" ]] || return 0
    if grep -qxF "$desc_line" "$CASK"; then return 0; fi
    local tmp
    tmp="$(mktemp)"
    sed -E -e "s|^  desc \"[^\"]+\"$|$desc_line|" "$CASK" > "$tmp"
    cat "$tmp" > "$CASK"
    rm -f "$tmp"
    echo "ok: $CASK desc set from $TEMPLATE"
}

current="$(sed -nE 's/^  version "([^"]+)"$/\1/p' "$CASK")"
current_sha="$(sed -nE 's/^  sha256 "([^"]+)"$/\1/p' "$CASK")"
if [[ "$current" == "0.0.0" && "$current_sha" =~ ^0{64}$ ]]; then
    current="none yet"
elif [[ "$current" == "$VERSION" ]]; then
    if [[ "$current_sha" == "$SHA256" ]]; then
        sync_desc
        echo "ok: $CASK already names $VERSION"
        exit 0
    fi
    echo "error: $CASK already names $VERSION with a different sha256; a release is never rewritten" >&2
    exit 1
fi
if [[ "$current" != "none yet" && "$(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
    echo "error: $CASK is at $current, newer than $VERSION" >&2
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -E -e "s/^  version \"[^\"]+\"$/  version \"$VERSION\"/" -e "s/^  sha256 \"[^\"]+\"$/  sha256 \"$SHA256\"/" "$CASK" > "$tmp"
cat "$tmp" > "$CASK"
sync_desc
echo "ok: $CASK $current -> $VERSION"
