#!/usr/bin/env bash
# scan-binary.sh must find a marker planted in a copy of a binary, report
# a clean copy as clean, and fail closed when it cannot read the file. The
# planted case is the one a pipe into `grep -q` gets wrong under pipefail
# (the reason the script exists); the marker is planted before the Mach-O
# and after it (where macOS `strings` would not even look).
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

marker='--preview-setup'
cp /bin/ls "$work/clean"
printf '%s\n' "$marker" > "$work/early"
cp /bin/ls "$work/late"
command cat /bin/ls >> "$work/early"
printf '%s\n' "$marker" >> "$work/late"

if ! ./scan-binary.sh "$work/clean" "$marker" >/dev/null; then
    echo "error: a clean binary was reported as contaminated" >&2; exit 1
fi
for variant in early late; do
    if ./scan-binary.sh "$work/$variant" "$marker" >/dev/null; then
        echo "error: the planted marker was not found ($variant)" >&2; exit 1
    fi
    report="$(./scan-binary.sh "$work/$variant" "$marker" || true)"
    [[ "$report" == "found: ${marker}" ]] || { echo "error: the finding was not reported ($variant): '${report}'" >&2; exit 1; }
done
# Several needles: one hit is enough.
if ./scan-binary.sh "$work/late" 'OPENREACTION_UPDATE_TEST_ACTION' "$marker" >/dev/null; then
    echo "error: a hit among several needles was missed" >&2; exit 1
fi
# A missing file is unverified (2), not clean (0).
set +e
./scan-binary.sh "$work/missing" "$marker" >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 2 ]] || { echo "error: a missing binary exited ${status}, expected 2" >&2; exit 1; }
echo "ok: scan-binary.sh finds planted markers and fails closed"
