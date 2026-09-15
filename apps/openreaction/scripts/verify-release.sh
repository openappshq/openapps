#!/usr/bin/env bash
# Checks a release zip the way a user's Mac and the updater will: unpacks it,
# verifies the app's signature and, for a release, that its designated
# requirement is exactly the pinned one (RELEASES.md, "Verification before
# publishing").
#
#   scripts/verify-release.sh dist/OpenReaction-1.2.3.zip             # local, ad-hoc OK
#   scripts/verify-release.sh --release dist/OpenReaction-1.2.3.zip   # release: everything must pass
#
# Without --release an ad-hoc signed build only gets the structural checks
# (signature integrity, bundle layout, universal binary, derived build
# number, updater configuration); the designated requirement is reported,
# not compared.
# With --release the requirement must equal release/designated-requirement.txt
# (PINNED_REQUIREMENT_FILE overrides the path for local rehearsals), the
# updater must be compiled in with the committed public key, and nothing of
# the update-test variant may be present. Notarization and Gatekeeper are not
# involved: the app is not notarized, and the cask clears quarantine.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_RELEASE=0
if [[ "${1:-}" == "--release" ]]; then REQUIRE_RELEASE=1; shift; fi
ZIP="${1:?path to the zip}"
APP_NAME="OpenReaction"
BUNDLE_ID="com.openappshq.openreaction"
PINNED_REQUIREMENT_FILE="${PINNED_REQUIREMENT_FILE:-release/designated-requirement.txt}"
test -f "$ZIP" || { echo "error: ${ZIP} not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/openreaction-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> Unpacking ${ZIP}"
ditto -x -k "$ZIP" "$WORK"
APP="$WORK/${APP_NAME}.app"
test -d "$APP" || { echo "error: ${APP_NAME}.app is not at the top of the zip" >&2; exit 1; }
[[ "$(find "$WORK" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 1 ]] || { echo "error: the zip must contain only ${APP_NAME}.app" >&2; exit 1; }

echo "==> App bundle"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
info() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION="$(info CFBundleShortVersionString)"
BUILD="$(info CFBundleVersion)"
echo "version: ${VERSION} (${BUILD})"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version '${VERSION}' is not MAJOR.MINOR.PATCH" >&2; exit 1; }
IFS=. read -r major minor patch <<< "$VERSION"
[[ "$BUILD" == "$(( major * 1000000 + minor * 1000 + patch ))" ]] \
    || { echo "error: CFBundleVersion ${BUILD} is not derived from ${VERSION} (RELEASES.md: builds order as releases do)" >&2; exit 1; }
echo "bundle id: $(info CFBundleIdentifier)"
[[ "$(info CFBundleIdentifier)" == "$BUNDLE_ID" ]] || { echo "error: bundle identifier is not ${BUNDLE_ID}" >&2; exit 1; }
[[ "$ZIP" == *"/${APP_NAME}-${VERSION}.zip" || "$ZIP" == "${APP_NAME}-${VERSION}.zip" ]] \
    || { echo "error: ${ZIP} is not named after the app's version ${VERSION}" >&2; exit 1; }
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

echo "==> Signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Captured once: piping codesign straight into `grep -q` lets grep close the
# pipe early, and under pipefail codesign's SIGPIPE then reads as a failure.
signature="$(codesign --display --verbose=2 "$APP" 2>&1)"
grep -E '^(Authority|Identifier|Timestamp|CodeDirectory)' <<< "$signature" || true
grep -q 'flags=.*runtime' <<< "$signature" || { echo "error: hardened runtime is off" >&2; exit 1; }
requirement="$(codesign --display -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
echo "designated requirement: ${requirement:-none}"
if [[ "$REQUIRE_RELEASE" == 1 ]]; then
    pinned="$(tr -d '\r' < "$PINNED_REQUIREMENT_FILE" | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true)"
    [[ "$pinned" == "identifier \"${BUNDLE_ID}\" and certificate leaf = H\""*'"' ]] \
        || { echo "error: ${PINNED_REQUIREMENT_FILE} does not hold a requirement for ${BUNDLE_ID} (RELEASING.md, \"Signing certificate and update key\")" >&2; exit 1; }
    ../../scripts/release/verify-designated-requirement.sh "$APP" "$PINNED_REQUIREMENT_FILE"
    grep -q '^Authority=OpenApps HQ Release$' <<< "$signature" || { echo "error: not signed by 'OpenApps HQ Release'" >&2; exit 1; }
fi

echo "==> Debug-only code"
# The setup preview harness (`--preview-setup`) is compiled only into debug
# builds; a bundle is always a release-configuration build, so the flag
# must not survive into the binary. scan-binary.sh searches the file's
# bytes directly and exits 0 only when it could read them all (never a
# pipe into grep -q, which fails open under pipefail).
if ! scripts/scan-binary.sh "$APP/Contents/MacOS/${APP_NAME}" '--preview-setup'; then
    echo "error: the binary contains the debug-only setup preview (or could not be scanned)" >&2; exit 1
fi
echo "ok: no setup preview"

echo "==> Updater"
feed="$(info SUFeedURL)"
key="$(info SUPublicEDKey)"
test ! -d "$APP/Contents/Frameworks" || { echo "error: the app embeds frameworks; the updater is compiled in" >&2; exit 1; }
if [[ "$REQUIRE_RELEASE" == 1 || -n "$feed" ]]; then
    [[ "$feed" == "https://openapps.space/updates/openreaction/appcast.xml" ]] || { echo "error: SUFeedURL is '${feed}'" >&2; exit 1; }
    [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "error: SUPublicEDKey is missing" >&2; exit 1; }
    if [[ "$REQUIRE_RELEASE" == 1 ]]; then
        committed="$(head -n 1 release/sparkle-public-key.txt)"
        [[ "$key" == "$committed" ]] || { echo "error: SUPublicEDKey is not the committed update key" >&2; exit 1; }
    fi
    [[ -z "$(info CFBundleURLTypes)" ]] && { echo "error: the openreaction:// URL scheme is missing" >&2; exit 1; }
    if ! scripts/scan-binary.sh "$APP/Contents/MacOS/${APP_NAME}" OPENREACTION_UPDATE_TEST_ACTION OPENREACTION_DISABLE_TAP; then
        echo "error: the binary contains update-test hooks (or could not be scanned)" >&2; exit 1
    fi
    [[ -z "$(info NSAppTransportSecurity)" ]] || { echo "error: App Transport Security exceptions in a release" >&2; exit 1; }
    echo "ok: feed ${feed}, key pinned, updater compiled in (automatic checks off by default)"
else
    echo "ok: no updater (source build)"
fi

echo "==> Verified ${ZIP}"
