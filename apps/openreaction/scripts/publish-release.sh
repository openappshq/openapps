#!/usr/bin/env bash
# Publishes a verified zip as the GitHub Release for openreaction-v<version>,
# and only when the tag names exactly the commit the zip was built from and
# the zip is byte-for-byte the one that passed verification.
#
#   GH_REPO=owner/repo TAG=openreaction-v1.2.3 VERSION=1.2.3 \
#   BUILT_COMMIT=<sha> EXPECTED_SHA256=<digest> RULESET_READ_TOKEN=<token> \
#   DIST=dist scripts/publish-release.sh [--dry-run]
#
# EXPECTED_SHA256 is the digest the release job computed from the zip it
# verified, carried as a job output rather than as a file next to the zip;
# a checksum file that travelled with the download proves nothing and is
# ignored. RULESET_READ_TOKEN reads the tag ruleset as a caller that is
# shown its bypass actors (scripts/release/release-tag-ruleset.sh at the repository root).
#
# Optional: CREATE_TAG=true lets a missing tag be created at BUILT_COMMIT
# (manual runs from a branch); ALLOW_OLDER=true permits publishing a version
# lower than the newest published release. --dry-run performs every check
# and stops before the first change to the repository.
#
# Order of operations, each of which fails closed:
#   1. the downloaded zip has exactly the expected digest;
#   2. an active ruleset makes openreaction-v* tags immutable (moves and
#      deletions blocked, nobody exempt) — the actual guarantee that the tag
#      cannot change underneath this script;
#   3. the tag exists (or is created) and resolves to BUILT_COMMIT;
#   4. no newer version is already published (unless ALLOW_OLDER);
#   5. no published release exists for the tag: a bad release gets a new
#      patch version, never a rewrite; leftover drafts are discarded;
#   6. a draft release is created and the assets uploaded — from here on,
#      leaving for any reason deletes the draft first;
#   7. the tag is resolved again and compared, and only then is the draft
#      published.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi
: "${GH_REPO:?owner/repo}"
: "${TAG:?release tag}"
: "${VERSION:?MAJOR.MINOR.PATCH}"
: "${BUILT_COMMIT:?commit the assets were built from}"
: "${EXPECTED_SHA256:?SHA-256 of the verified zip, from the release job}"
if [[ -z "${RULESET_READ_TOKEN:-}" ]]; then
    echo "error: RULESET_READ_TOKEN is not set; the tag ruleset cannot be checked for hidden bypass actors (RELEASING.md)" >&2
    exit 1
fi
DIST="${DIST:-dist}"
CREATE_TAG="${CREATE_TAG:-false}"
ALLOW_OLDER="${ALLOW_OLDER:-false}"
ZIP="OpenReaction-${VERSION}.zip"
SUM="${ZIP}.sha256"
[[ "$TAG" == "openreaction-v${VERSION}" ]] || { echo "error: TAG ${TAG} does not match VERSION ${VERSION}" >&2; exit 1; }
[[ "$BUILT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: BUILT_COMMIT must be a full commit SHA" >&2; exit 1; }
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: EXPECTED_SHA256 must be a lowercase hex SHA-256" >&2; exit 1; }

stop_if_dry_run() {
    if [[ "$DRY_RUN" == "1" ]]; then echo "==> Dry run: would $1; stopping before any change."; exit 0; fi
}

sha256_of() {
    if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# The commit a remote tag names, peeled through annotated tags; empty when
# the tag does not exist. Any other API failure fails the script.
tag_commit() {
    local ref sha type depth=0
    if ! ref="$(gh api "repos/$GH_REPO/git/ref/tags/$TAG" 2>&1)"; then
        case "$ref" in *"HTTP 404"*|*"Not Found"*) return 0 ;; esac
        echo "error: could not read tag $TAG: $ref" >&2; return 1
    fi
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

# Every release as JSON, or failure. Drafts are only visible by listing,
# since releases/tags/<tag> does not return them.
all_releases() {
    gh api "repos/$GH_REPO/releases" --paginate
}

# Draft release ids for TAG, one per line; fails when the list cannot be read.
draft_ids_for_tag() {
    local list
    list="$(all_releases)" || { echo "error: could not list releases on $GH_REPO" >&2; return 1; }
    # shellcheck disable=SC2016  # $tag is a jq variable
    printf '%s' "$list" | jq -r --arg tag "$TAG" '.[] | select(.tag_name == $tag and .draft) | .id'
}

# Deletes every draft release for TAG; a published one is never touched.
# Loud and fatal when a draft cannot be removed.
delete_drafts() {
    local ids id
    ids="$(draft_ids_for_tag)" || return 1
    if [[ -n "${DRAFT_ID:-}" ]] && ! printf '%s\n' "$ids" | grep -qx "$DRAFT_ID"; then ids="$DRAFT_ID"$'\n'"$ids"; fi
    for id in $ids; do
        echo "==> Discarding draft release #${id}"
        if ! gh api --method DELETE "repos/$GH_REPO/releases/$id" >/dev/null; then
            echo "error: could not delete draft release #${id} for $TAG; remove it by hand before the next run" >&2
            return 1
        fi
    done
}

echo "==> Checking ${DIST}/${ZIP} against the verified digest"
test -f "$DIST/$ZIP" || { echo "error: ${DIST}/${ZIP} not found" >&2; exit 1; }
actual="$(sha256_of "$DIST/$ZIP")"
if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    echo "error: ${ZIP} has SHA-256 ${actual}, but the release job verified ${EXPECTED_SHA256}; this is not the verified build" >&2
    exit 1
fi
# The checksum published next to the zip is written from the verified
# digest, never taken from whatever came with the download.
printf '%s  %s\n' "$EXPECTED_SHA256" "$ZIP" > "$DIST/$SUM"
echo "ok: ${ZIP} ${EXPECTED_SHA256}"

echo "==> Checking tag protection on ${GH_REPO}"
../../scripts/release/release-tag-ruleset.sh check .github/rulesets/openreaction-release-tags.json "$GH_REPO"

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
releases="$(all_releases)" || { echo "error: could not list releases on $GH_REPO" >&2; exit 1; }
newest="$(printf '%s' "$releases" \
    | jq -r '.[] | select(.draft | not) | .tag_name | select(startswith("openreaction-v")) | ltrimstr("openreaction-v")' \
    | { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n 1)"
if [[ -n "$newest" && "$newest" != "$VERSION" && "$(printf '%s\n%s\n' "$newest" "$VERSION" | sort -V | tail -n 1)" == "$newest" ]]; then
    if [[ "$ALLOW_OLDER" != "true" ]]; then
        echo "error: $newest is already published, which is newer than $VERSION; set allow_older to publish an older version on purpose" >&2
        exit 1
    fi
    echo "warning: publishing $VERSION below the newest published release $newest (allow_older)"
fi

echo "==> Checking for an existing release"
# shellcheck disable=SC2016  # $tag is a jq variable
if printf '%s' "$releases" | jq -e --arg tag "$TAG" 'any(.[]; .tag_name == $tag and (.draft | not))' >/dev/null; then
    echo "error: $TAG is already published; a release is never rewritten. Fix forward with a new patch version." >&2
    exit 1
fi
stop_if_dry_run "create a draft release for $TAG (discarding any leftover draft), upload $ZIP and $SUM, and publish"
delete_drafts

# From here until the draft is published, leaving for any reason — an error,
# a cancelled job, a lost create response — removes whatever draft exists
# for the tag. Only a successful publish clears the flag.
PUBLISHED=0
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$PUBLISHED" == 1 ]]; then exit "$status"; fi
    echo "==> Not published; removing any draft for ${TAG}"
    if ! delete_drafts; then
        echo "error: a draft for $TAG may remain; delete it by hand" >&2
    fi
    exit $(( status == 0 ? 1 : status ))
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> Creating draft release ${TAG}"
# The list endpoint can lag a few seconds behind a just-created draft, so the
# id comes from the creation response itself, never from a later listing.
DRAFT_ID="$(gh api --method POST "repos/$GH_REPO/releases" \
    -f tag_name="$TAG" -f target_commitish="$BUILT_COMMIT" -f name="OpenReaction ${VERSION}" \
    -F draft=true -F prerelease=false -F generate_release_notes=true --jq .id)" || DRAFT_ID=""
if [[ ! "$DRAFT_ID" =~ ^[0-9]+$ ]]; then
    echo "error: creating the draft release failed" >&2
    exit 1
fi
echo "ok: draft release #${DRAFT_ID}"

gh release upload "$TAG" --repo "$GH_REPO" "$DIST/$ZIP" "$DIST/$SUM"

echo "==> Confirming ${TAG} still names ${BUILT_COMMIT}"
now="$(tag_commit)"
if [[ "$now" != "$BUILT_COMMIT" ]]; then
    echo "error: $TAG changed to '$now' while publishing; nothing was published" >&2
    exit 1
fi

echo "==> Publishing ${TAG}"
gh api --method PATCH "repos/$GH_REPO/releases/$DRAFT_ID" -F draft=false >/dev/null
PUBLISHED=1
gh release view "$TAG" --repo "$GH_REPO" --json url --jq .url
