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
#
# GitHub includes `bypass_actors` in a ruleset only for callers allowed to
# administer it; everyone else gets the ruleset without that field, which
# would look exactly like "nobody is exempt". The check therefore treats a
# missing field as unknown and fails, and reads rulesets with
# RULESET_READ_TOKEN when it is set: a fine-grained token with read access
# to repository administration, used for nothing else. Without it the
# ambient gh login is used, which is fine for an admin running this by hand.
set -euo pipefail
cd "$(dirname "$0")/../../.."

ACTION="${1:?check|apply}"
REPO="${2:-${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}}"
DEFINITION=".github/rulesets/openreaction-release-tags.json"
PATTERN="$(jq -r '.conditions.ref_name.include[0]' "$DEFINITION")"

# gh for reading rulesets: with the dedicated token when one is given.
read_api() {
    if [[ -n "${RULESET_READ_TOKEN:-}" ]]; then
        GH_TOKEN="$RULESET_READ_TOKEN" gh api "$@"
    else
        gh api "$@"
    fi
}

# A ruleset qualifies when it is active, targets tags, covers the release tag
# pattern (exactly, or every ref) without exclusions, blocks updates,
# non-fast-forward pushes and deletions, and explicitly lists no bypass
# actors: the field must be present and be an empty array.
qualifies() {
    jq -e --arg pattern "$PATTERN" '
        .target == "tag"
        and .enforcement == "active"
        and has("bypass_actors") and (.bypass_actors | type == "array" and length == 0)
        and ((.conditions.ref_name.include // []) | any(. == $pattern or . == "~ALL"))
        and ((.conditions.ref_name.exclude // []) | length == 0)
        and ([.rules[]?.type] | (index("update") != null and index("deletion") != null and index("non_fast_forward") != null))
    ' >/dev/null
}

check() {
    local ids id ruleset hidden=0
    ids="$(read_api "repos/$REPO/rulesets" --paginate --jq '.[] | select(.target == "tag") | .id')"
    for id in $ids; do
        ruleset="$(read_api "repos/$REPO/rulesets/$id")"
        if printf '%s' "$ruleset" | qualifies; then
            echo "ok: ruleset $(printf '%s' "$ruleset" | jq -r '.name') (#$id) protects $PATTERN on $REPO"
            return 0
        fi
        if ! printf '%s' "$ruleset" | jq -e 'has("bypass_actors")' >/dev/null; then hidden=1; fi
    done
    if [[ "$hidden" == 1 ]]; then
        cat >&2 <<MSG
error: a tag ruleset on $REPO does not show its bypass actors to this caller, so it cannot be trusted.
Read rulesets with RULESET_READ_TOKEN, a fine-grained token with read access to the repository's
administration (see apps/openreaction/RELEASING.md).
MSG
        return 1
    fi
    cat >&2 <<MSG
error: no active ruleset on $REPO makes $PATTERN tags immutable.
Releases are not published until one exists. Apply the checked-in definition
with: scripts/release-tag-ruleset.sh apply $REPO  (see apps/openreaction/RELEASING.md)
MSG
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
