#!/usr/bin/env bash
# Checks a built DMG the way a user's Mac will: mounts it, verifies the app's
# signature, Gatekeeper assessment and stapled notarization ticket, then does
# the same for the disk image itself.
#
#   scripts/verify-release.sh dist/OpenReaction-1.2.3.dmg             # local, ad-hoc OK
#   scripts/verify-release.sh --notarized dist/OpenReaction-1.2.3.dmg # release: everything must pass
#
# Without --notarized an ad-hoc signed build only gets the structural checks
# (signature integrity, bundle layout, universal binary); Gatekeeper and
# stapler are reported but do not fail the script, since they cannot pass
# without a Developer ID identity and a notary ticket.
set -euo pipefail

REQUIRE_NOTARIZED=0
if [[ "${1:-}" == "--notarized" ]]; then REQUIRE_NOTARIZED=1; shift; fi
DMG="${1:?path to the DMG}"
APP_NAME="OpenReaction"
test -f "$DMG" || { echo "error: ${DMG} not found" >&2; exit 1; }

MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/openreaction-verify.XXXXXX")"
cleanup() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT

check() {
    # check <label> <command...>: fatal when notarization is required, a
    # warning otherwise.
    local label="$1"; shift
    if "$@"; then
        echo "ok: ${label}"
    elif [[ "$REQUIRE_NOTARIZED" == "1" ]]; then
        echo "FAIL: ${label}" >&2
        exit 1
    else
        echo "skip: ${label} (needs a Developer ID signature and notarization)"
    fi
}

echo "==> Disk image"
codesign --verify --verbose=2 "$DMG"
check "DMG Gatekeeper assessment" spctl --assess --type open --context context:primary-signature -vv "$DMG"
check "DMG notarization ticket" xcrun stapler validate "$DMG"

echo "==> Mounting ${DMG}"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
APP="$MOUNT/${APP_NAME}.app"
test -d "$APP" || { echo "error: ${APP_NAME}.app missing from the DMG" >&2; exit 1; }
test -L "$MOUNT/Applications" || { echo "error: Applications link missing from the DMG" >&2; exit 1; }

echo "==> App bundle"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "version: $(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist"))"
echo "bundle id: $(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
archs="$(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
echo "architectures: ${archs}"
for arch in arm64 x86_64; do
    case " $archs " in
        *" $arch "*) ;;
        *) echo "error: not a universal binary, ${arch} is missing (got '${archs}')" >&2; exit 1 ;;
    esac
done
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/emoji.json"
codesign --verify --deep --strict --verbose=2 "$APP"
# Captured once: piping codesign straight into `grep -q` lets grep close the
# pipe early, and under pipefail codesign's SIGPIPE then reads as a failure.
signature="$(codesign --display --verbose=2 "$APP" 2>&1)"
grep -E '^(Authority|Identifier|TeamIdentifier|Timestamp|CodeDirectory)' <<< "$signature" || true
grep -q 'flags=.*runtime' <<< "$signature" || { echo "error: hardened runtime is off" >&2; exit 1; }
if [[ "$REQUIRE_NOTARIZED" == "1" ]]; then
    grep -q 'Authority=Developer ID Application:' <<< "$signature" \
        || { echo "error: not signed with a Developer ID Application identity" >&2; exit 1; }
fi
check "app Gatekeeper assessment" spctl --assess --type execute -vv "$APP"
check "app notarization ticket" xcrun stapler validate "$APP"

echo "==> Verified ${DMG}"
