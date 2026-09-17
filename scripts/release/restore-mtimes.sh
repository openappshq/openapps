#!/usr/bin/env bash
# Gives every tracked file under the given paths the modification time of
# the commit that last changed it, so a build directory restored from the
# cache sees unchanged sources as unchanged (RELEASES.md, "Pipeline"). A
# checkout stamps every file with the time it was written, which makes an
# incremental build start over; SwiftPM and the Swift driver decide by
# modification time, so commit times — the same on every runner — keep the
# increments. Needs the history (fetch-depth: 0).
#
#   scripts/release/restore-mtimes.sh <path>...
set -euo pipefail

[[ $# -gt 0 ]] || { echo "usage: restore-mtimes.sh <path>..." >&2; exit 1; }
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
    echo "error: the history is shallow; check out with fetch-depth: 0" >&2; exit 1
fi

# Newest commit first, each followed by the paths it touched: a path takes
# the first (newest) time it appears. Times are UTC in touch's -t form and
# applied under TZ=UTC, so the zone never shifts them.
count=0
while IFS= read -r line; do
    if [[ "$line" == @* ]]; then
        stamp="${line#@}"
    elif [[ -n "$line" && -f "$line" ]]; then
        TZ=UTC touch -m -t "$stamp" -- "$line"
        count=$((count + 1))
    fi
done < <(TZ=UTC git -c core.quotePath=false log --format='@%cd' --date=format-local:%Y%m%d%H%M.%S --name-only -- "$@" \
    | awk '!/^@/ { if (seen[$0]++) next } { print }')
echo "Restored the commit times of $count files under: $*"
