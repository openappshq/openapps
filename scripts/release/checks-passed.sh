#!/usr/bin/env bash
# Finds a finished run of a workflow, for one commit, whose check jobs all
# passed recently — the evidence a publish dispatch relies on instead of
# running the checks again (RELEASES.md, "Pipeline").
#
#   scripts/release/checks-passed.sh <workflow file> <sha>
#
# Looks at the workflow's completed runs for the commit, newest first, and
# takes the first whose check jobs — every job except preflight, release,
# publish and feed — all concluded `success`, with the last of them finished
# within CHECKS_MAX_AGE_HOURS (default 24). A run whose checks were skipped
# (a dispatch that relied on an earlier run, a push that touched nothing the
# checks cover) is no evidence and is passed over.
#
# Prints the run id on stdout and exits 0 when found; 1 when no run
# qualifies; 2 when the API could not be read. The caller runs the checks on
# anything but 0. Reads the API with `gh api` (GH_TOKEN, GH_REPO), needs jq.
# CHECKS_NOW (epoch seconds) fixes "now" for the tests.
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
if ! ids="$(printf '%s' "$runs" | jq -r --arg sha "$SHA" '.workflow_runs[] | select(.head_sha == $sha) | .id')"; then
    echo "error: unexpected run listing for $WORKFLOW" >&2
    exit 2
fi
if [[ -z "$ids" ]]; then
    echo "No completed run of $WORKFLOW for $SHA." >&2
    exit 1
fi

for id in $ids; do
    if ! jobs="$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100")"; then
        echo "error: could not read the jobs of run $id" >&2
        exit 2
    fi
    # "passed <epoch of the last check job's end>", or one word saying why not.
    verdict="$(printf '%s' "$jobs" | jq -r '
        [.jobs[] | select(.name | IN("preflight", "release", "publish", "feed") | not)]
        | if length == 0 then "no-checks"
          elif all(.conclusion == "success") then "passed " + (map(.completed_at | fromdateiso8601) | max | tostring)
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
        no-checks) echo "Run $id: no check job." >&2 ;;
        *) echo "Run $id: a check job did not pass." >&2 ;;
    esac
done
echo "No run of $WORKFLOW for $SHA passed its checks within ${MAX_AGE_HOURS} h." >&2
exit 1
