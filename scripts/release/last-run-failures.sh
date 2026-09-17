#!/usr/bin/env bash
# What the branch's last run of a workflow left failed, so the next run
# does it again whatever its own change touched (RELEASES.md, "Pipeline").
#
#   scripts/release/last-run-failures.sh <workflow file> <branch>
#
# Looks at the newest completed run of the workflow on the branch. Prints
# the check jobs — every job except preflight, release, publish and feed —
# that did not pass or get skipped (failed, cancelled, timed out), one per
# line, for changes.sh to redo. A run that failed before any check job
# could pass (preflight itself, say) prints `ALL`. A run that passed, or
# whose only failure was in release, publish or feed, and no run at all,
# print nothing. Exits 0 in every case that could be read; 2 when the API
# could not be, which the caller treats as `ALL`. Reads the API with
# `gh api` (GH_TOKEN, GH_REPO), needs jq.
set -euo pipefail

WORKFLOW="${1:?usage: last-run-failures.sh <workflow file> <branch>}"
BRANCH="${2:?usage: last-run-failures.sh <workflow file> <branch>}"
REPO="${GH_REPO:?GH_REPO must name the repository (owner/name)}"
[[ "$WORKFLOW" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || { echo "error: workflow must be a file name like macpaper.yml" >&2; exit 2; }

encoded_branch="$(jq -rn --arg b "$BRANCH" '$b | @uri')"
if ! runs="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?branch=$encoded_branch&status=completed&per_page=1")"; then
    echo "error: could not list the completed runs of $WORKFLOW on $BRANCH" >&2
    exit 2
fi
read -r id conclusion < <(printf '%s' "$runs" | jq -r '.workflow_runs[0] | if . == null then "none none" else "\(.id) \(.conclusion)" end')
if [[ "$id" == none ]]; then
    echo "No completed run of $WORKFLOW on $BRANCH yet." >&2
    exit 0
fi
if ! jobs="$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100")"; then
    echo "error: could not read the jobs of run $id" >&2
    exit 2
fi
failed="$(printf '%s' "$jobs" | jq -r '
    [.jobs[] | select(.name | IN("preflight", "release", "publish", "feed") | not)]
    | map(select(.conclusion != "success" and .conclusion != "skipped") | .name) | .[]')"
passed_any="$(printf '%s' "$jobs" | jq -r '
    [.jobs[] | select(.name | IN("preflight", "release", "publish", "feed") | not)]
    | any(.conclusion == "success")')"
if [[ -n "$failed" ]]; then
    echo "Run $id ($conclusion) left these check jobs unfinished; they run again:" >&2
    printf '%s\n' "$failed" | sed 's/^/  /' >&2
    printf '%s\n' "$failed"
elif [[ "$conclusion" != success && "$passed_any" != true ]]; then
    echo "Run $id ($conclusion) passed no check job; everything runs again." >&2
    echo ALL
else
    echo "Run $id ($conclusion): nothing left over from the checks." >&2
fi
