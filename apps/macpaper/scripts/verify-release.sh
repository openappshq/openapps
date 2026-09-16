#!/usr/bin/env bash
# Checks a release zip the way a user's Mac and the updater will: unpacks it,
# verifies the app's signature and, for a release, that its designated
# requirement is exactly the pinned one (RELEASES.md, "Verification before
# publishing").
#
#   scripts/verify-release.sh dist/macPaper-1.2.3.zip             # local, ad-hoc OK
#   scripts/verify-release.sh --release dist/macPaper-1.2.3.zip   # release: everything must pass
#
# Without --release an ad-hoc signed build only gets the structural checks
# (signature integrity, bundle layout, universal binary, derived build
# number, updater configuration); the designated requirement is reported,
# not compared. With --release the requirement must equal
# release/designated-requirement.txt (PINNED_REQUIREMENT_FILE overrides the
# path for local rehearsals), the signer must be the OpenApps HQ Release
# certificate, licensing must be compiled in against Dodo's live host, the
# updater must be compiled in with the committed public key, and nothing of
# the update-test variant may be present. Notarization and Gatekeeper are
# not involved: the app is not notarized, and the cask clears quarantine.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_RELEASE=0
if [[ "${1:-}" == "--release" ]]; then REQUIRE_RELEASE=1; shift; fi
ZIP="${1:?path to the zip}"
APP_NAME="macPaper"
BUNDLE_ID="com.openappshq.macpaper"
PINNED_REQUIREMENT_FILE="${PINNED_REQUIREMENT_FILE:-release/designated-requirement.txt}"
test -f "$ZIP" || { echo "error: ${ZIP} not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macpaper-verify.XXXXXX")"
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
[[ "$(info LSUIElement)" == "true" ]] || { echo "error: LSUIElement is not set; macPaper is a menu-bar app" >&2; exit 1; }
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
test ! -d "$APP/Contents/Frameworks" || { echo "error: the app embeds frameworks; macPaper has none (the updater is compiled in)" >&2; exit 1; }
[[ -z "$(info NSAppTransportSecurity)" ]] || { echo "error: App Transport Security exceptions in a release" >&2; exit 1; }
# The binary's strings, read once into a file: piped straight into `grep -q`,
# an early match closes the pipe, strings dies of SIGPIPE, and under pipefail
# the whole test reads as "no match".
STRINGS="$WORK/strings.txt"
if ! strings "$APP/Contents/MacOS/${APP_NAME}" > "$STRINGS"; then
    echo "error: could not read the binary's strings" >&2; exit 1
fi
# The standalone repository's self-updater fetched the repository-wide latest
# GitHub release; nothing may bring that back.
if grep -Fq 'api.github.com' "$STRINGS"; then
    echo "error: the binary references the GitHub API; updates come from the signed feed only (RELEASES.md)" >&2; exit 1
fi
# The debug preview harness (PreviewHarness.swift, `--preview`) is compiled
# only under DEBUG; a release binary that carries its markers was built wrong.
if grep -Eq 'PREVIEW_(WROTE|RENDERED|DESKTOP_CALLS)|--preview' "$STRINGS"; then
    echo "error: the binary contains the debug preview harness" >&2; exit 1
fi

echo "==> Licensing"
# The compiled-in configuration (LICENSING.md, "Build flavours"): a release
# talks to Dodo's live host and the trial registry with the real product ID.
# A test-mode build (the CI checks job, a local rehearsal) is reported; a
# source build has none of it. The placeholder ID the checks job compiles
# with must never be in a release, nor may a release name the test host.
has() { grep -Fq "$1" "$STRINGS"; }
if has 'dodopayments.com'; then
    if has 'live.dodopayments.com'; then env_name="live"; elif has 'test.dodopayments.com'; then env_name="test"; else env_name="unknown"; fi
    has 'openapps.space/api/trial' || { echo "error: licensing is compiled in but the trial registry URL is missing" >&2; exit 1; }
    has 'pdt_' || { echo "error: licensing is compiled in but no Dodo product ID is" >&2; exit 1; }
    echo "licensing: on (Dodo ${env_name}, trial registry https://openapps.space/api/trial)"
    if grep -Eiq 'pdt_[A-Za-z0-9_-]*(placeholder|todo|example|dummy)' "$STRINGS"; then
        [[ "$REQUIRE_RELEASE" == 0 ]] || { echo "error: the release binary contains a placeholder Dodo product ID" >&2; exit 1; }
        echo "note: placeholder product ID (a checks build; never a release)"
    fi
    if [[ "$REQUIRE_RELEASE" == 1 ]]; then
        [[ "$env_name" == live ]] || { echo "error: a release must be built with OPENAPPS_DODO_ENV=live (found ${env_name})" >&2; exit 1; }
        if has 'test.dodopayments.com'; then echo "error: the release binary names Dodo's test host" >&2; exit 1; fi
        if grep -Eq 'http://(127\.0\.0\.1|localhost)' "$STRINGS"; then echo "error: the release binary names a local trial registry" >&2; exit 1; fi
    fi
    [[ -n "$(info CFBundleURLTypes)" ]] || { echo "error: the macpaper:// URL scheme is missing" >&2; exit 1; }
else
    for needle in 'licenses/activate' 'openapps.space/api/trial' 'IOPlatformExpertDevice'; do
        if has "$needle"; then echo "error: licensing is compiled out but the binary contains '${needle}'" >&2; exit 1; fi
    done
    [[ "$REQUIRE_RELEASE" == 0 ]] || { echo "error: a release must have licensing compiled in (OPENAPPS_LICENSING=1)" >&2; exit 1; }
    echo "licensing: off (source build: no trial, no license network calls)"
fi

echo "==> Updater"
# The shared updater (RELEASES.md, "In-app updater"): an official build pins
# the feed and the public key in Info.plist and carries nothing of the
# update-test variant; a source build has no updater at all.
feed="$(info SUFeedURL)"
key="$(info SUPublicEDKey)"
if [[ "$REQUIRE_RELEASE" == 1 || -n "$feed" ]]; then
    [[ "$feed" == "https://openapps.space/updates/macpaper/appcast.xml" ]] || { echo "error: SUFeedURL is '${feed}'" >&2; exit 1; }
    [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "error: SUPublicEDKey is missing" >&2; exit 1; }
    if [[ "$REQUIRE_RELEASE" == 1 ]]; then
        committed="$(head -n 1 release/sparkle-public-key.txt)"
        [[ "$key" == "$committed" ]] || { echo "error: SUPublicEDKey is not the committed update key" >&2; exit 1; }
    fi
    [[ -n "$(info CFBundleURLTypes)" ]] || { echo "error: the macpaper:// URL scheme is missing" >&2; exit 1; }
    if grep -Fq 'MACPAPER_UPDATE_TEST_ACTION' "$STRINGS"; then
        echo "error: the binary contains update-test hooks" >&2; exit 1
    fi
    echo "updater: on (feed ${feed}, key pinned; automatic checks on for a fresh install, downloads off)"
else
    if grep -Fq '/updates/macpaper/' "$STRINGS"; then
        echo "error: the updater is compiled out but the binary names the feed" >&2; exit 1
    fi
    echo "updater: off (source build: no update checks)"
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
        || { echo "error: ${PINNED_REQUIREMENT_FILE} does not hold a requirement for ${BUNDLE_ID} (RELEASING.md, \"Signing certificate and update key\")" >&2; exit 1; }
    ../../scripts/release/verify-designated-requirement.sh "$APP" "$PINNED_REQUIREMENT_FILE"
    grep -q '^Authority=OpenApps HQ Release$' <<< "$signature" || { echo "error: not signed by 'OpenApps HQ Release'" >&2; exit 1; }
fi

echo "==> Verified ${ZIP}"
