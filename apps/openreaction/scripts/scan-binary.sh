#!/usr/bin/env bash
# Whether a binary contains any of the given strings, for the release gates
# that refuse debug-only code (scripts/verify-release.sh).
#
#   scripts/scan-binary.sh <binary> <string>...
#
# Exit 0: none found. 1: at least one found (each is printed). 2: the file
# could not be read, which counts as unverified, never as clean.
#
# The file's bytes are searched directly (`grep -a -F`), so a string is found
# wherever it sits: any section of any slice of a universal binary, or bytes
# appended after the Mach-O, which macOS `strings` skips. There is no pipe:
# `strings | grep -q` lets grep close the pipe on the first match, the
# producer dies of SIGPIPE, and under pipefail the pipeline reads as "not
# found" — the opposite of the truth. scripts/tests/scan-binary.test.sh
# plants a marker in copies of a binary and checks that it is caught.
set -euo pipefail

binary="${1:?path to the binary}"
shift
[[ $# -gt 0 ]] || { echo "usage: scan-binary.sh <binary> <string>..." >&2; exit 2; }
test -r "$binary" || { echo "error: ${binary} is not a readable file" >&2; exit 2; }

found=0
for needle in "$@"; do
    set +e
    grep -q -a -F -- "$needle" "$binary"
    status=$?
    set -e
    case "$status" in
        0) echo "found: ${needle}"; found=1 ;;
        1) ;;
        *) echo "error: could not search ${binary} (grep exited ${status})" >&2; exit 2 ;;
    esac
done
exit "$found"
