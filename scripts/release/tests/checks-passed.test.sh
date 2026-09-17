#!/usr/bin/env bash
# checks-passed.sh and last-run-failures.sh against recorded API answers
# (fixtures/checks-passed): a run that passed is found, a targeted run whose
# plan skipped jobs counts, and a failed, cancelled, stale, skipped,
# skipped-against-plan, suite-less, other-workflow or other-commit run never
# does; an API that is down is told apart from "no evidence". The last
# run's leftovers are named exactly.
set -euo pipefail
cd "$(dirname "$0")/.."
fixtures="$PWD/tests/fixtures/checks-passed"
sha=0123456789abcdef0123456789abcdef01234567
export PATH="$fixtures:$PATH" GH_REPO=openappshq/openapps
# 2026-09-17T00:00:00Z: the fixtures' timestamps are relative to this.
export CHECKS_NOW=1789603200

expect() {
    local label="$1" case="$2" want_status="$3" want_output="$4"; shift 4
    local output status=0
    output="$(CHECKS_FIXTURE_CASE="$case" ./checks-passed.sh "$@" 2>/dev/null)" || status=$?
    if [[ "$status" != "$want_status" || "$output" != "$want_output" ]]; then
        echo "error ($label): exit $status with '$output', expected exit $want_status with '$want_output'" >&2
        exit 1
    fi
    echo "ok: $label"
}

expect "a run that passed an hour ago" success 0 100 macpaper.yml "$sha"
expect "a check job failed" failure 1 "" macpaper.yml "$sha"
expect "passed, but 28 h ago" stale 1 "" macpaper.yml "$sha"
expect "no run for the commit" none 1 "" macpaper.yml "$sha"
expect "another workflow's run" wrong-workflow 1 "" macpaper.yml "$sha"
expect "another commit's run" wrong-sha 1 "" macpaper.yml "$sha"
# The newest run relied on an earlier one (its checks were skipped); the earlier run is the evidence.
expect "the newest run skipped its checks, the one before passed" skipped-then-passed 0 100 macpaper.yml "$sha"
CHECKS_MAX_AGE_HOURS=1 expect "the same, 2 h old under a 1 h limit" skipped-then-passed 1 "" macpaper.yml "$sha"
expect "the run was cancelled after its checks passed" cancelled-run 1 "" macpaper.yml "$sha"
# A tests-only push: the plan skipped packages and lint, the suites ran.
expect "a targeted run, skipped jobs by plan" targeted 0 100 macpaper.yml "$sha"
expect "a job skipped against the plan" skipped-against-plan 1 "" macpaper.yml "$sha"
expect "skipped jobs with no plan recorded" targeted-no-plan 1 "" macpaper.yml "$sha"
expect "a run whose plan had no suite" no-suites 1 "" macpaper.yml "$sha"
expect "the API is down" api-error 2 "" macpaper.yml "$sha"
expect "a malformed sha" success 2 "" macpaper.yml not-a-sha
expect "a path instead of a workflow file" success 2 "" "../../etc/passwd" "$sha"

# last-run-failures.sh: what the branch's newest run left behind.
last() {
    local label="$1" case="$2" want_status="$3" want_output="$4"
    local output status=0
    output="$(CHECKS_FIXTURE_CASE="$case" ./last-run-failures.sh macpaper.yml main 2>/dev/null)" || status=$?
    if [[ "$status" != "$want_status" || "$output" != "$want_output" ]]; then
        echo "error ($label): exit $status with '$output', expected exit $want_status with '$want_output'" >&2
        exit 1
    fi
    echo "ok: $label"
}
last "a failed package job is redone" last-failed-packages 0 "packages"
last "cancelled legs are redone" last-cancelled-legs 0 $'checks (source)\nchecks (official)'
last "a green run leaves nothing" last-green 0 ""
last "a run that broke before its checks: everything" last-preflight-broke 0 "ALL"
last "a failure in release leaves the checks alone" last-release-failed 0 ""
last "no run yet" last-none 0 ""
last "the API is down" api-error 2 ""
