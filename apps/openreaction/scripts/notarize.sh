#!/usr/bin/env bash
# Submits an app bundle or DMG to Apple's notary service, waits for the
# verdict and staples the ticket. Needs APPLE_ID, APPLE_PASSWORD (an
# app-specific password) and APPLE_TEAM_ID, and an item that was signed with a
# Developer ID Application identity, hardened runtime and a secure timestamp.
#
#   scripts/notarize.sh build/OpenReaction.app
#   scripts/notarize.sh dist/OpenReaction-1.2.3.dmg
#
# The app is notarized first and stapled, then packaged, and the DMG is
# notarized and stapled as well, so both the disk image and the app a user
# copies out of it validate without contacting Apple.
set -euo pipefail

ITEM="${1:?path to a .app or .dmg}"
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_PASSWORD:?APPLE_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
test -e "$ITEM" || { echo "error: ${ITEM} not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/openreaction-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

case "$ITEM" in
    *.app)
        # notarytool takes zip, dmg or pkg; the ticket is stapled to the bundle.
        SUBMISSION="$WORK/$(basename "$ITEM").zip"
        ditto -c -k --keepParent "$ITEM" "$SUBMISSION"
        ;;
    *.dmg) SUBMISSION="$ITEM" ;;
    *) echo "error: ${ITEM} is neither a .app nor a .dmg" >&2; exit 1 ;;
esac

echo "==> Submitting $(basename "$ITEM") for notarization"
RESULT="$WORK/result.plist"
# --wait returns 0 even for Invalid or Rejected; the status field decides.
xcrun notarytool submit "$SUBMISSION" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" \
    --wait --timeout 30m --output-format plist > "$RESULT"
ID="$(plutil -extract id raw -o - "$RESULT")"
STATUS="$(plutil -extract status raw -o - "$RESULT")"
echo "==> Submission ${ID}: ${STATUS}"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "==> Notary log:"
    xcrun notarytool log "$ID" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" || true
    exit 1
fi

echo "==> Stapling ${ITEM}"
xcrun stapler staple "$ITEM"
xcrun stapler validate "$ITEM"
