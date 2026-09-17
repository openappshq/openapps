#!/usr/bin/env bash
# Makes a build directory restored from the cache see unchanged sources as
# unchanged, and changed ones as changed (RELEASES.md, "Pipeline").
#
#   scripts/release/restore-mtimes.sh <marker file> <path>...
#
# A checkout stamps every file with the time it was written, which makes an
# incremental build start over. So every tracked file under the paths that
# is byte-for-byte what the cached build compiled gets the time of the
# commit that last changed it — the same value that build saw — and every
# file that differs keeps the checkout's "now", newer than anything in the
# cache. That holds for a build system that compares times for equality
# (SwiftPM, the Swift driver) and for one that asks "newer than my output"
# (Cargo): a commit time can be older than the cached build, so a changed
# file must never receive one.
#
# Which commit the cache was built from is the marker file, kept inside the
# cached directory: this script reads it, and writes the current commit
# back so the cache saved from this run carries its own. No marker (a cache
# miss, or a cache from before this scheme) restores nothing: a full build
# is the safe answer. Needs the history (fetch-depth: 0).
set -euo pipefail

MARKER="${1:?usage: restore-mtimes.sh <marker file> <path>...}"
shift
[[ $# -gt 0 ]] || { echo "usage: restore-mtimes.sh <marker file> <path>..." >&2; exit 1; }
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
    echo "error: the history is shallow; check out with fetch-depth: 0" >&2; exit 1
fi
head="$(git rev-parse HEAD)"

base=""
if [[ -f "$MARKER" ]]; then
    base="$(tr -d '[:space:]' < "$MARKER")"
    if [[ ! "$base" =~ ^[0-9a-f]{40}$ ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
        echo "The cache names commit '${base}', which this checkout does not have: every file keeps the checkout time."
        base=""
    fi
fi

restored=0 changed=0
if [[ -n "$base" ]]; then
    # Every file the cached build compiled differently from this checkout, or
    # did not have at all; renames count on both sides.
    changed_list="$(git -c core.quotePath=false diff --name-only "$base" "$head" -- "$@")"
    # Newest commit first, each followed by the paths it touched: a path takes
    # the first (newest) time it appears. Times are UTC in touch's -t form and
    # applied under TZ=UTC, so the zone never shifts them.
    while IFS= read -r line; do
        if [[ "$line" == @* ]]; then
            stamp="${line#@}"
        elif [[ -n "$line" && -f "$line" ]]; then
            if grep -Fxq -- "$line" <<< "$changed_list"; then changed=$((changed + 1)); continue; fi
            TZ=UTC touch -m -t "$stamp" -- "$line"
            restored=$((restored + 1))
        fi
    done < <(TZ=UTC git -c core.quotePath=false log --format='@%cd' --date=format-local:%Y%m%d%H%M.%S --name-only -- "$@" \
        | awk '!/^@/ { if (seen[$0]++) next } { print }')
    echo "Cache built from ${base:0:7}: $restored unchanged files got their commit times, $changed changed files keep the checkout time."
else
    echo "No cache commit to compare against: every file keeps the checkout time."
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$head" > "$MARKER"
