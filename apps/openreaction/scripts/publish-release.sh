#!/usr/bin/env bash
# Publishes a verified DMG as the GitHub Release for openreaction-v<version>,
# and only when the tag names exactly the commit the DMG was built from.
#
#   GH_REPO=owner/repo TAG=openreaction-v1.2.3 VERSION=1.2.3 \
#   BUILT_COMMIT=<sha> DIST=dist scripts/publish-release.sh [--dry-run]
#
# Optional: CREATE_TAG=true lets a missing tag be created at BUILT_COMMIT
# (manual runs from a branch); ALLOW_OLDER=true permits publishing a version
# lower than the newest published release. --dry-run performs every check
# and stops before the first change to the repository.
#
# Order of operations, each of which fails closed:
#   1. the checksum file matches the DMG;
#   2. an active ruleset makes openreaction-v* tags immutable (moves and
#      deletions blocked, nobody exempt) — the actual guarantee that the tag
#      cannot change underneath this script;
#   3. the tag exists (or is created) and resolves to BUILT_COMMIT;
#   4. no newer version is already published (unless ALLOW_OLDER);
#   5. no published release exists for the tag: a bad release gets a new
#      patch version, never a rewrite; a leftover draft is discarded;
#   6. a draft release is created and the assets uploaded;
#   7. the tag is resolved again and compared, the draft is deleted on any
#      difference, and only then is the draft published.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi
: "${GH_REPO:?owner/repo}"
: "${TAG:?release tag}"
: "${VERSION:?MAJOR.MINOR.PATCH}"
: "${BUILT_COMMIT:?commit the assets were built from}"
DIST="${DIST:-dist}"
CREATE_TAG="${CREATE_TAG:-false}"
ALLOW_OLDER="${ALLOW_OLDER:-false}"
DMG="OpenReaction-${VERSION}.dmg"
SUM="${DMG}.sha256"
[[ "$TAG" == "openreaction-v${VERSION}" ]] || { echo "error: TAG ${TAG} does not match VERSION ${VERSION}" >&2; exit 1; }
[[ "$BUILT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: BUILT_COMMIT must be a full commit SHA" >&2; exit 1; }

stop_if_dry_run() {
    if [[ "$DRY_RUN" == "1" ]]; then echo "==> Dry run: would $1; stopping before any change."; exit 0; fi
}

# The commit a remote tag names, peeled through annotated tags; empty when
# the tag does not exist.
tag_commit() {
    local ref sha type depth=0
    ref="$(gh api "repos/$GH_REPO/git/ref/tags/$TAG" 2>/dev/null)" || return 0
    sha="$(printf '%s' "$ref" | jq -r .object.sha)"
    type="$(printf '%s' "$ref" | jq -r .object.type)"
    while [[ "$type" == "tag" ]]; do
        depth=$((depth + 1))
        if (( depth > 5 )); then echo "error: $TAG is nested more than 5 annotated tags deep" >&2; return 1; fi
        ref="$(gh api "repos/$GH_REPO/git/tags/$sha")"
        sha="$(printf '%s' "$ref" | jq -r .object.sha)"
        type="$(printf '%s' "$ref" | jq -r .object.type)"
    done
    [[ "$type" == "commit" ]] || { echo "error: $TAG points at a $type, not a commit" >&2; return 1; }
    printf '%s\n' "$sha"
}

# Releases for TAG, one "<id> <draft>" per line. Drafts are found by
# listing, since releases/tags/<tag> does not return them.
releases_for_tag() {
    # shellcheck disable=SC2016  # $tag is a jq variable
    gh api "repos/$GH_REPO/releases" --paginate \
        | jq -r --arg tag "$TAG" '.[] | select(.tag_name == $tag) | "\(.id) \(.draft)"'
}

# Deletes every draft release for TAG (a published one is never touched).
delete_drafts() {
    local rel
    while read -r rel; do
        [[ -n "$rel" && "${rel#* }" == "true" ]] || continue
        echo "==> Discarding draft release #${rel% *}"
        gh api --method DELETE "repos/$GH_REPO/releases/${rel% *}" >/dev/null || true
    done <<< "$(releases_for_tag)"
}

echo "==> Checking ${DIST}/${DMG}"
if command -v shasum >/dev/null; then
    (cd "$DIST" && shasum -a 256 -c "$SUM")
else
    (cd "$DIST" && sha256sum -c "$SUM")
fi

echo "==> Checking tag protection on ${GH_REPO}"
scripts/release-tag-ruleset.sh check "$GH_REPO"

echo "==> Resolving ${TAG}"
existing="$(tag_commit)"
if [[ -z "$existing" ]]; then
    if [[ "$CREATE_TAG" != "true" ]]; then
        echo "error: tag $TAG does not exist on $GH_REPO" >&2; exit 1
    fi
    stop_if_dry_run "create $TAG at $BUILT_COMMIT"
    echo "==> Creating ${TAG} at ${BUILT_COMMIT}"
    gh api --method POST "repos/$GH_REPO/git/refs" -f ref="refs/tags/$TAG" -f sha="$BUILT_COMMIT" >/dev/null
    existing="$(tag_commit)"
fi
if [[ "$existing" != "$BUILT_COMMIT" ]]; then
    echo "error: $TAG points at $existing but these assets were built from $BUILT_COMMIT; refusing to publish. Release the tagged commit, or use a new version." >&2
    exit 1
fi
echo "ok: $TAG -> $existing"

echo "==> Checking published versions"
newest="$(gh api "repos/$GH_REPO/releases" --paginate \
    --jq '.[] | select(.draft | not) | .tag_name | select(startswith("openreaction-v")) | ltrimstr("openreaction-v")' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
if [[ -n "$newest" && "$newest" != "$VERSION" && "$(printf '%s\n%s\n' "$newest" "$VERSION" | sort -V | tail -n 1)" == "$newest" ]]; then
    if [[ "$ALLOW_OLDER" != "true" ]]; then
        echo "error: $newest is already published, which is newer than $VERSION; set allow_older to publish an older version on purpose" >&2
        exit 1
    fi
    echo "warning: publishing $VERSION below the newest published release $newest (allow_older)"
fi

echo "==> Checking for an existing release"
releases="$(releases_for_tag)"
if grep -q ' false$' <<< "$releases"; then
    echo "error: $TAG is already published; a release is never rewritten. Fix forward with a new patch version." >&2
    exit 1
fi
stop_if_dry_run "create a draft release for $TAG (discarding any leftover draft), upload $DMG and $SUM, and publish"
delete_drafts

echo "==> Creating draft release ${TAG}"
gh release create "$TAG" --repo "$GH_REPO" --draft --verify-tag --title "OpenReaction ${VERSION}" --generate-notes >/dev/null
trap 'echo "==> Failed; removing the draft"; delete_drafts' ERR
gh release upload "$TAG" --repo "$GH_REPO" "$DIST/$DMG" "$DIST/$SUM"

echo "==> Confirming ${TAG} still names ${BUILT_COMMIT}"
now="$(tag_commit)"
if [[ "$now" != "$BUILT_COMMIT" ]]; then
    trap - ERR
    delete_drafts
    echo "error: $TAG changed to '$now' while publishing; the draft is discarded and nothing was published" >&2
    exit 1
fi

echo "==> Publishing ${TAG}"
gh release edit "$TAG" --repo "$GH_REPO" --draft=false >/dev/null
trap - ERR
gh release view "$TAG" --repo "$GH_REPO" --json url --jq .url
