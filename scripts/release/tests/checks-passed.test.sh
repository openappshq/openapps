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
    # A direct hit's evidence sha is the commit itself: $sha here always.
    local label="$1" case="$2" want_status="$3" want_run="$4"; shift 4
    local output status=0 want=""
    [[ "$want_status" == 0 ]] && want="$want_run"$'\n'"$sha"
    output="$(CHECKS_FIXTURE_CASE="$case" ./checks-passed.sh "$@" 2>/dev/null)" || status=$?
    if [[ "$status" != "$want_status" || "$output" != "$want" ]]; then
        echo "error ($label): exit $status with '$output', expected exit $want_status with '$want'" >&2
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

# Walkback: a manual dispatch that lands on a feed-only commit (the
# pipeline's own commit to the feed and install script, or another app's)
# accepts an earlier ancestor's passed run instead of finding none
# (feed-paths.txt says which paths are feed-only). A throwaway git history
# stands in for the checkout the real workflow gives the script.
script="$PWD/checks-passed.sh"
walkback="$(mktemp -d)"
trap 'rm -rf "$walkback" "$fixtures"/walkback-*' EXIT

# build_chain <dir> <kind>...: a fresh repo with an empty root commit, then
# one commit per kind ("feed" touches the feed path, "other" a source
# path). Prints every commit's sha, oldest first, the root included.
build_chain() {
    local dir="$1"; shift
    rm -rf "$dir" && mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" -c user.email=t@t.test -c user.name=test commit -q --allow-empty -m root
    git -C "$dir" rev-parse HEAD
    local n=0 kind
    for kind in "$@"; do
        n=$((n + 1))
        case "$kind" in
            feed) mkdir -p "$dir/apps/website/public/updates/macpaper"
                  echo "$n" > "$dir/apps/website/public/updates/macpaper/appcast.xml" ;;
            other) mkdir -p "$dir/apps/macpaper/Sources"
                   echo "$n" > "$dir/apps/macpaper/Sources/Base.swift" ;;
        esac
        git -C "$dir" add -A
        git -C "$dir" -c user.email=t@t.test -c user.name=test commit -q -m "commit $n ($kind)"
        git -C "$dir" rev-parse HEAD
    done
}
# evidence_case <case> <passing sha>: a fixture whose only passed run of
# macpaper.yml is for <passing sha> (jobs-100.json's checks, reused as-is).
evidence_case() {
    local case_dir="$fixtures/$1" passing="$2"
    rm -rf "$case_dir" && mkdir -p "$case_dir"
    printf '{"total_count": 1, "workflow_runs": [{"id": 900, "head_sha": "%s", "status": "completed", "conclusion": "success", "path": ".github/workflows/macpaper.yml"}]}' "$passing" > "$case_dir/runs-macpaper.yml.json"
    cp "$fixtures/success/jobs-100.json" "$case_dir/jobs-900.json"
}
# cancelled_case <case> <sha>: a fixture whose only run at <sha> was cancelled.
cancelled_case() {
    local case_dir="$fixtures/$1" sha="$2"
    rm -rf "$case_dir" && mkdir -p "$case_dir"
    printf '{"total_count": 1, "workflow_runs": [{"id": 900, "head_sha": "%s", "status": "completed", "conclusion": "cancelled", "path": ".github/workflows/macpaper.yml"}]}' "$sha" > "$case_dir/runs-macpaper.yml.json"
}
# expect_walk <label> <case> <repo dir> <target sha> <status> [<run> <ancestor>]
expect_walk() {
    local label="$1" case="$2" dir="$3" target="$4" want_status="$5" want_run="${6-}" want_ancestor="${7-}"
    local output status=0 want=""
    [[ "$want_status" == 0 ]] && want="$want_run"$'\n'"$want_ancestor"
    output="$(cd "$dir" && CHECKS_FIXTURE_CASE="$case" "$script" macpaper.yml "$target" 2>/dev/null)" || status=$?
    if [[ "$status" != "$want_status" || "$output" != "$want" ]]; then
        echo "error ($label): exit $status with '$output', expected exit $want_status with '$want'" >&2
        exit 1
    fi
    echo "ok: $label"
}

# root -> other (a real source push: the evidence) -> feed -> feed -> feed.
behind=()
while IFS= read -r sha; do behind+=("$sha"); done < <(build_chain "$walkback/behind" other feed feed feed)
evidence_case walkback-behind "${behind[1]}"
expect_walk "a direct hit still wins over the walk" walkback-behind "$walkback/behind" "${behind[1]}" 0 900 "${behind[1]}"
expect_walk "one feed commit behind" walkback-behind "$walkback/behind" "${behind[2]}" 0 900 "${behind[1]}"
expect_walk "three feed commits behind" walkback-behind "$walkback/behind" "${behind[4]}" 0 900 "${behind[1]}"

# root -> feed (the evidence) -> other -> feed: a non-feed commit sits
# between the evidence and the target, so the walk must never reach it.
nonfeed=()
while IFS= read -r sha; do nonfeed+=("$sha"); done < <(build_chain "$walkback/nonfeed" feed other feed)
evidence_case walkback-nonfeed "${nonfeed[1]}"
expect_walk "a non-feed commit in between refused" walkback-nonfeed "$walkback/nonfeed" "${nonfeed[3]}" 1

# root (a cancelled run) -> feed: the one ancestor there is has no evidence,
# and there is no history before it.
cancelled=()
while IFS= read -r sha; do cancelled+=("$sha"); done < <(build_chain "$walkback/cancelled" feed)
cancelled_case walkback-cancelled "${cancelled[0]}"
expect_walk "a cancelled run at the ancestor refused" walkback-cancelled "$walkback/cancelled" "${cancelled[1]}" 1

# root (the evidence, 11 commits back — past the 10-ancestor limit) -> 11
# feed commits.
limit=()
while IFS= read -r sha; do limit+=("$sha"); done < <(build_chain "$walkback/walklimit" feed feed feed feed feed feed feed feed feed feed feed)
evidence_case walkback-walklimit "${limit[0]}"
expect_walk "the walk stops at 10 ancestors" walkback-walklimit "$walkback/walklimit" "${limit[11]}" 1

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
