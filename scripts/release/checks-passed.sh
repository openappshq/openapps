#!/usr/bin/env bash
# Finds a finished run of a workflow, for one commit, whose check jobs all
# passed recently — the evidence a publish dispatch relies on instead of
# running the checks again (RELEASES.md, "Pipeline").
#
#   scripts/release/checks-passed.sh <workflow file> <sha>
#
# Looks at the workflow's completed runs for the commit, newest first, and
# takes the first that concluded `success` (a cancelled or failed run is
# none, however its jobs ended) whose check jobs — every job except
# preflight, release, publish and feed — all passed, with the last of them
# finished within CHECKS_MAX_AGE_HOURS (default 24). The run's own plan
# (the `preflight` artifact its preflight job uploads: what the change
# called for) says which of its jobs were skipped by design; a skipped job
# the plan wanted, or a run whose plan left out the source or the flavour
# suites, is no evidence. Without a plan (an older run) every check job
# must have passed. A dispatch that relied on an earlier run, or a push
# that touched nothing the suites cover, is therefore passed over.
#
# Prints the run id on stdout and exits 0 when found; 1 when no run
# qualifies; 2 when the API could not be read. The caller runs the checks on
# anything but 0. Reads the API with `gh api` and `gh run download`
# (GH_TOKEN, GH_REPO), needs jq. CHECKS_NOW (epoch seconds) fixes "now" for
# the tests.
set -euo pipefail

WORKFLOW="${1:?usage: checks-passed.sh <workflow file> <sha>}"
SHA="${2:?usage: checks-passed.sh <workflow file> <sha>}"
MAX_AGE_HOURS="${CHECKS_MAX_AGE_HOURS:-24}"
NOW="${CHECKS_NOW:-$(date +%s)}"
REPO="${GH_REPO:?GH_REPO must name the repository (owner/name)}"
[[ "$WORKFLOW" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || { echo "error: workflow must be a file name like macpaper.yml" >&2; exit 2; }
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "error: sha must be a full 40-digit commit id" >&2; exit 2; }
[[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || { echo "error: CHECKS_MAX_AGE_HOURS must be a whole number of hours" >&2; exit 2; }

if ! runs="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?head_sha=$SHA&status=completed&per_page=20")"; then
    echo "error: could not list the completed runs of $WORKFLOW for $SHA" >&2
    exit 2
fi
# The API filters on head_sha; the check is repeated here so a surprise
# never becomes release evidence.
if ! listing="$(printf '%s' "$runs" | jq -r --arg sha "$SHA" '.workflow_runs[] | select(.head_sha == $sha) | "\(.id) \(.conclusion)"')"; then
    echo "error: unexpected run listing for $WORKFLOW" >&2
    exit 2
fi
if [[ -z "$listing" ]]; then
    echo "No completed run of $WORKFLOW for $SHA." >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The run's plan, as `name=value` lines, or nothing when it has none.
plan_of() {
    local id="$1"
    rm -rf "$work/plan"
    if gh run download "$id" --repo "$REPO" -n preflight -D "$work/plan" >/dev/null 2>&1 && [[ -f "$work/plan/plan.txt" ]]; then
        cat "$work/plan/plan.txt"
    fi
}
planned() { # planned <plan> <name>: the value the plan gives the name, or ""
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

while read -r id conclusion; do
    if [[ "$conclusion" != success ]]; then
        echo "Run $id: concluded $conclusion, not success." >&2
        continue
    fi
    if ! jobs="$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100")"; then
        echo "error: could not read the jobs of run $id" >&2
        exit 2
    fi
    plan="$(plan_of "$id")"
    if [[ -n "$plan" ]]; then
        # Skipped by design only: the plan must have left the job out, and the
        # plan must have included both suites for the run to prove anything.
        if [[ "$(planned "$plan" suite)" != true || "$(planned "$plan" flavour_suite)" != true ]]; then
            echo "Run $id: its plan did not include the source and flavour suites." >&2
            continue
        fi
        allowed_skips="$(jq -rn --arg f "$(planned "$plan" flavours)" --arg l "$(planned "$plan" licensing_tests)" \
            --arg u "$(planned "$plan" updater_tests)" --arg lint "$(planned "$plan" lint)" '
            [ (if $f == "[]" then "checks" else empty end),
              (if $l != "true" and $u != "true" then "packages" else empty end),
              (if $lint != "true" then "lint" else empty end) ] | @json')"
    else
        echo "Run $id: no plan recorded; every check job must have passed." >&2
        allowed_skips='[]'
    fi
    # "passed <epoch of the last check job's end>", or one word saying why not.
    verdict="$(printf '%s' "$jobs" | jq -r --argjson skips "$allowed_skips" '
        [.jobs[] | select(.name | IN("preflight", "release", "publish", "feed") | not)] as $checks
        | ($checks | map(select(.conclusion == "success"))) as $passed
        | if ($checks | length) == 0 or ($passed | length) == 0 then "no-checks"
          elif ($checks | all(.conclusion == "success" or (.conclusion == "skipped" and (.name | IN($skips[])))))
          then "passed " + ($passed | map(.completed_at | fromdateiso8601) | max | tostring)
          else "not-passed"
          end')" || { echo "error: unexpected job listing for run $id" >&2; exit 2; }
    case "$verdict" in
        passed\ *)
            finished="${verdict#passed }"
            age=$(( NOW - finished ))
            if (( age <= MAX_AGE_HOURS * 3600 )); then
                echo "Run $id: every check job passed, the last $(( age / 60 )) min ago." >&2
                echo "$id"
                exit 0
            fi
            echo "Run $id: every check job passed, but $(( age / 3600 )) h ago (limit ${MAX_AGE_HOURS} h)." >&2 ;;
        no-checks) echo "Run $id: no check job passed." >&2 ;;
        *) echo "Run $id: a check job did not pass, or was skipped against its plan." >&2 ;;
    esac
done <<< "$listing"
echo "No run of $WORKFLOW for $SHA passed its checks within ${MAX_AGE_HOURS} h." >&2
exit 1
