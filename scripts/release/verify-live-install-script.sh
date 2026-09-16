#!/usr/bin/env bash
# Checks the install script users actually get (RELEASES.md, "Install
# script"): https://openapps.space/install/<app-id> must pin the released
# version and the digest the release job verified, be served as a shell
# script, parse, and end in the call that runs it.
#
#   scripts/release/verify-live-install-script.sh <app-id> <version> <expected sha256>
#
# Waits up to WAIT_SECONDS (default 600; the feed and the script deploy
# together, so the feed check before this one usually has already waited)
# for the served script to pin the version. When the committed file
# apps/website/public/install/<app-id> exists next to this checkout, the
# served bytes must equal it. OPENAPPS_INSTALL_URL_BASE (default
# https://openapps.space/install/) points the check at another server.
set -euo pipefail
cd "$(dirname "$0")/../.."

APP_ID="${1:?usage: verify-live-install-script.sh <app-id> <version> <expected sha256>}"
VERSION="${2:?usage: verify-live-install-script.sh <app-id> <version> <expected sha256>}"
EXPECTED_SHA256="${3:?usage: verify-live-install-script.sh <app-id> <version> <expected sha256>}"
WAIT_SECONDS="${WAIT_SECONDS:-600}"
BASE="${OPENAPPS_INSTALL_URL_BASE:-https://openapps.space/install/}"
[[ "$APP_ID" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "error: app id must be lowercase letters, digits and dashes" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "error: expected sha256 must be 64 lowercase hex digits" >&2; exit 1; }
URL="${BASE}${APP_ID}"

work="$(mktemp -d "${TMPDIR:-/tmp}/${APP_ID}-install-live.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "==> Waiting for ${URL} to pin ${VERSION}"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
pinned=""
while :; do
    # Cache-busting query: the edge may keep the script for five minutes.
    # %{content_type} is the final response's, after any redirect.
    if curl -fsSL -H 'Cache-Control: no-cache' -o "$work/script" -w '%{content_type}' "${URL}?t=$(date +%s)" > "$work/content-type" \
        && grep -q "^VERSION='${VERSION}'$" "$work/script"; then
        pinned=1
        break
    fi
    if (( $(date +%s) >= deadline )); then break; fi
    sleep 30
done
[[ -n "$pinned" ]] || { echo "error: ${URL} still does not pin ${VERSION} after ${WAIT_SECONDS}s" >&2; exit 1; }

sha256="$(sed -nE "s/^SHA256='([^']+)'$/\1/p" "$work/script")"
zip_url="$(sed -nE "s/^URL='([^']+)'$/\1/p" "$work/script")"
if [[ "$sha256" != "$EXPECTED_SHA256" ]]; then
    echo "error: ${URL} pins ${VERSION} with SHA-256 ${sha256}, not ${EXPECTED_SHA256}" >&2
    exit 1
fi
case "$zip_url" in
    "https://github.com/openappshq/openapps/releases/download/${APP_ID}-v${VERSION}/"*"-${VERSION}.zip") ;;
    *) echo "error: ${URL} downloads ${zip_url}, not the ${APP_ID}-v${VERSION} release zip" >&2; exit 1 ;;
esac
content_type="$(cat "$work/content-type")"
media_type="$(printf '%s' "${content_type%%;*}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
if [[ "$media_type" != "text/x-shellscript" ]]; then
    echo "error: ${URL} is served as '${content_type}', not text/x-shellscript" >&2
    exit 1
fi
[[ "$(tail -n 1 "$work/script")" == "main </dev/null" ]] || { echo "error: ${URL} does not end with the call to main; it may be truncated" >&2; exit 1; }
sh -n "$work/script" || { echo "error: ${URL} does not parse as sh" >&2; exit 1; }
committed="apps/website/public/install/${APP_ID}"
if [[ -f "$committed" ]] && ! cmp -s "$committed" "$work/script"; then
    echo "error: ${URL} differs from the committed ${committed}" >&2
    diff "$committed" "$work/script" >&2 || true
    exit 1
fi
echo "ok: ${URL} pins ${VERSION} ${EXPECTED_SHA256}, served as ${content_type}"
