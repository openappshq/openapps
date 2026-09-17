#!/usr/bin/env bash
# Turns a list of test patterns into one `swift test --filter` expression
# (RELEASES.md, "Pipeline": the flavour suites an official-flavour check
# runs come from apps/<app>/scripts/flavour-tests.txt).
#
#   swift test --filter "$(scripts/release/test-filter.sh apps/<app>/scripts/flavour-tests.txt)"
#
# One pattern per line, matched against test identifiers the way --filter
# does (`Module`, `Module.Suite`, `Module.Suite/test`); blank lines and
# `#` comments are ignored; an empty list is an error, so a filter can
# never silently select nothing.
set -euo pipefail

FILE="${1:?usage: test-filter.sh <patterns file>}"
patterns="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$FILE")"
[[ -n "$patterns" ]] || { echo "error: $FILE names no test pattern" >&2; exit 1; }
printf '%s\n' "$patterns" | paste -sd '|' -
