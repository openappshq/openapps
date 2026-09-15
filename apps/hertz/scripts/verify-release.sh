#!/usr/bin/env bash
# Checks a release zip the way a user's Mac will: unpacks it, verifies the
# app's signature and, for a release, that its designated requirement is
# exactly the pinned one (RELEASES.md, "Verification before publishing").
#
#   scripts/verify-release.sh dist/Hertz-1.2.3.zip             # local, ad-hoc OK
#   scripts/verify-release.sh --release dist/Hertz-1.2.3.zip   # release: everything must pass
#
# Without --release an ad-hoc signed build only gets the structural checks
# (signature integrity, bundle layout, universal binary); the designated
# requirement is reported, not compared. With --release the requirement must
# equal release/designated-requirement.txt (PINNED_REQUIREMENT_FILE overrides
# the path for local rehearsals) and the signer must be the OpenApps HQ
# Release certificate. Notarization and Gatekeeper are not involved: the app
# is not notarized, and the cask clears quarantine.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_RELEASE=0
if [[ "${1:-}" == "--release" ]]; then REQUIRE_RELEASE=1; shift; fi
ZIP="${1:?path to the zip}"
APP_NAME="Hertz"
BUNDLE_ID="com.openappshq.hertz"
PINNED_REQUIREMENT_FILE="${PINNED_REQUIREMENT_FILE:-release/designated-requirement.txt}"
test -f "$ZIP" || { echo "error: ${ZIP} not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hertz-verify.XXXXXX")"
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
echo "version: ${VERSION} ($(info CFBundleVersion))"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version '${VERSION}' is not MAJOR.MINOR.PATCH" >&2; exit 1; }
[[ "$(info CFBundleVersion)" =~ ^[0-9]+$ ]] || { echo "error: CFBundleVersion is not an integer" >&2; exit 1; }
echo "bundle id: $(info CFBundleIdentifier)"
[[ "$(info CFBundleIdentifier)" == "$BUNDLE_ID" ]] || { echo "error: bundle identifier is not ${BUNDLE_ID}" >&2; exit 1; }
[[ "$ZIP" == *"/${APP_NAME}-${VERSION}.zip" || "$ZIP" == "${APP_NAME}-${VERSION}.zip" ]] \
    || { echo "error: ${ZIP} is not named after the app's version ${VERSION}" >&2; exit 1; }
[[ "$(info LSUIElement)" == "true" ]] || { echo "error: LSUIElement is not set; Hertz is a menu-bar app" >&2; exit 1; }
archs="$(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
echo "architectures: ${archs}"
for arch in arm64 x86_64; do
    case " $archs " in
        *" $arch "*) ;;
        *) echo "error: not a universal binary, ${arch} is missing (got '${archs}')" >&2; exit 1 ;;
    esac
done
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/MenuBarIcon@2x.png"
test -f "$APP/Contents/Resources/Fonts/IBMPlexMono-Regular.ttf"
test -f "$APP/Contents/Resources/NOTICE"
test ! -d "$APP/Contents/Frameworks" || { echo "error: the app embeds frameworks; Hertz has none" >&2; exit 1; }
[[ -z "$(info NSAppTransportSecurity)" ]] || { echo "error: App Transport Security exceptions in a release" >&2; exit 1; }
# No in-app updater (RELEASES.md): nothing in the bundle may name a feed or a
# release API.
if strings "$APP/Contents/MacOS/${APP_NAME}" | grep -Eq 'api\.github\.com|/updates/hertz/|SUFeedURL'; then
    echo "error: the binary references an update feed; Hertz updates through Homebrew only" >&2; exit 1
fi

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
        || { echo "error: ${PINNED_REQUIREMENT_FILE} does not hold a requirement for ${BUNDLE_ID} (RELEASING.md, \"Signing certificate\")" >&2; exit 1; }
    ../../scripts/release/verify-designated-requirement.sh "$APP" "$PINNED_REQUIREMENT_FILE"
    grep -q '^Authority=OpenApps HQ Release$' <<< "$signature" || { echo "error: not signed by 'OpenApps HQ Release'" >&2; exit 1; }
fi

echo "==> Verified ${ZIP}"
