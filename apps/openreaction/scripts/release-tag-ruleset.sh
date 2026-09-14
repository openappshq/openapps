#!/usr/bin/env bash
# The repository ruleset that makes an openreaction-v* tag immutable once it
# exists (no moves, no force pushes, no deletion, nobody exempt), so a
# release can never end up carrying binaries built from a different commit.
# The definition is .github/rulesets/openreaction-release-tags.json.
#
#   scripts/release-tag-ruleset.sh check [owner/repo]   # exit 1 unless an equivalent active ruleset exists
#   scripts/release-tag-ruleset.sh apply [owner/repo]   # create it (needs admin on the repository)
#
# The release workflow runs `check` before publishing and refuses to publish
# without it; `apply` is a one-time admin step (RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/../../.."

ACTION="${1:?check|apply}"
REPO="${2:-${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}}"
DEFINITION=".github/rulesets/openreaction-release-tags.json"
PATTERN="$(jq -r '.conditions.ref_name.include[0]' "$DEFINITION")"

# A ruleset qualifies when it is active, targets tags, covers the release tag
# pattern (exactly, or every ref) without exclusions, blocks updates,
# non-fast-forward pushes and deletions, and has no bypass actors at all.
qualifies() {
    jq -e --arg pattern "$PATTERN" '
        .target == "tag"
        and .enforcement == "active"
        and ((.bypass_actors // []) | length == 0)
        and ((.conditions.ref_name.include // []) | any(. == $pattern or . == "~ALL"))
        and ((.conditions.ref_name.exclude // []) | length == 0)
        and ([.rules[]?.type] | (index("update") != null and index("deletion") != null and index("non_fast_forward") != null))
    ' >/dev/null
}

check() {
    local ids id ruleset
    ids="$(gh api "repos/$REPO/rulesets" --paginate --jq '.[] | select(.target == "tag") | .id')"
    for id in $ids; do
        ruleset="$(gh api "repos/$REPO/rulesets/$id")"
        if printf '%s' "$ruleset" | qualifies; then
            echo "ok: ruleset $(printf '%s' "$ruleset" | jq -r '.name') (#$id) protects $PATTERN on $REPO"
            return 0
        fi
    done
    cat >&2 <<EOF
error: no active ruleset on $REPO makes $PATTERN tags immutable.
Releases are not published until one exists. Apply the checked-in definition
with: scripts/release-tag-ruleset.sh apply $REPO  (see apps/openreaction/RELEASING.md)
EOF
    return 1
}

case "$ACTION" in
    check) check ;;
    apply)
        echo "==> Creating ruleset from $DEFINITION on $REPO"
        gh api --method POST "repos/$REPO/rulesets" --input "$DEFINITION" --jq '"created ruleset #\(.id): \(.name)"'
        check
        ;;
    *) echo "usage: $0 check|apply [owner/repo]" >&2; exit 2 ;;
esac
