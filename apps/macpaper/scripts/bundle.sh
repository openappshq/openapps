#!/usr/bin/env bash
# Builds a release binary and assembles a signed build/macPaper.app.
#
#   scripts/bundle.sh                                   # ad-hoc signed development build
#   RELEASE_SIGNING_P12=… RELEASE_SIGNING_P12_PASSWORD=… \
#   ../../scripts/release/with-signing-keychain.sh scripts/bundle.sh   # release signing
#
# Signing (RELEASES.md, "Why a stable self-signed certificate"): inside
# scripts/release/with-signing-keychain.sh, which imports the OpenApps HQ
# Release certificate into a temporary keychain and exports
# RELEASE_SIGNING_IDENTITY (its SHA-1) and RELEASE_SIGNING_KEYCHAIN, the app
# is signed with that certificate, the hardened runtime and the explicit
# designated requirement `identifier "<bundle id>" and certificate leaf = H"<sha1>"`,
# which must equal the one pinned in release/designated-requirement.txt.
# Without them the app is ad-hoc signed. macPaper asks for no permissions, so
# an ad-hoc development build loses nothing between rebuilds; the stable
# certificate is the identity every update must satisfy (the in-app updater
# evaluates it, and `brew upgrade` replaces the same app in place).
#
# Environment:
#
#   VERSION       CFBundleShortVersionString, MAJOR.MINOR.PATCH. Defaults to
#                 the `macpaper-vX.Y.Z` tag on HEAD, else 0.0.0 (a development
#                 build; official releases always come from a tag).
#                 CFBundleVersion is derived from it, MAJOR*1000000 + MINOR*1000
#                 + PATCH, so build order is release order: the updater compares
#                 builds, and a back-port from a later commit never outranks the
#                 release it patches. (Releases before the updater, 0.1.x, used
#                 the commit count; every derived build is higher.)
#   UNIVERSAL=1   Build one arm64 + x86_64 binary (the release configuration).
#                 Default: the host architecture only.
#   SCRATCH_PATH  SwiftPM's scratch path (default .build).
#
# Licensing (LICENSING.md) is compiled out by default. Official builds opt in:
#
#   OPENAPPS_LICENSING=1 OPENAPPS_DODO_ENV=test \
#   OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… scripts/bundle.sh
#
# OPENAPPS_DODO_ENV is `test` (test.dodopayments.com, trial registry
# env "test") or `live`. Optional: OPENAPPS_TRIAL_REGISTRY_BASE_URL (default
# https://openapps.space; a test build may use a local `wrangler dev` such as
# http://127.0.0.1:8787), OPENAPPS_BUY_URL (default https://openapps.space/macpaper/,
# the website page that states the price; the thanks page deep-links the key
# back as macpaper://activate?key=…) and OPENAPPS_SUPPORT_URL. The script
# generates Sources/MacPaper/Licensing/LicensingConfig.swift (gitignored) and
# refuses to build a licensed app without the paid product ID.
#
# Updates (RELEASES.md, "In-app updater") are compiled out by default too.
# OPENAPPS_OFFICIAL=1 compiles the shared OpenAppsUpdater package in and pins
# the feed (https://openapps.space/updates/macpaper/appcast.xml) and the public
# update key from release/sparkle-public-key.txt in Info.plist (SUFeedURL,
# SUPublicEDKey). A fresh install checks for updates automatically (decided
# once, with licensing's record store as the fresh-install test; RELEASES.md);
# downloads stay off until the user turns them on. Official releases set both
# OPENAPPS_LICENSING and OPENAPPS_OFFICIAL.
#
# An ad-hoc signed official build may pin a throwaway key instead with
# UPDATE_PUBLIC_ED_KEY (the CI checks job does); a release-signed build
# always pins the committed key.
#
# MACPAPER_UPDATE_TEST=1 (with OPENAPPS_OFFICIAL=1, never with
# OPENAPPS_LICENSING=1) builds the variant scripts/update-e2e.sh runs: bundle
# identifier com.openappshq.macpaper.updatetest, no URL scheme, no login item,
# no setup guide and no licensing (so no record store, registry or Dodo
# client; Sources/MacPaper/Updates/UpdateTesting.swift), and UPDATE_FEED_URL
# (an http://127.0.0.1 feed is allowed) overriding the pinned feed. None of
# that is accepted for any other build, and scripts/verify-release.sh
# refuses it.
#
# Signing uses the hardened runtime, no sandbox (the app writes where the
# user asks and hands files to NSWorkspace) and scripts/MacPaper.entitlements.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="macPaper"
# The SwiftPM product; the bundle's executable is renamed to the app name.
PRODUCT_NAME="MacPaper"
BUNDLE_ID="com.openappshq.macpaper"
APP="build/${APP_NAME}.app"
ENTITLEMENTS="scripts/${PRODUCT_NAME}.entitlements"
SCRATCH_PATH="${SCRATCH_PATH:-.build}"
FEED_URL="https://openapps.space/updates/macpaper/appcast.xml"
OFFICIAL="${OPENAPPS_OFFICIAL:-0}"
UPDATE_TEST="${MACPAPER_UPDATE_TEST:-0}"
if [[ "$UPDATE_TEST" == "1" && "$OFFICIAL" != "1" ]]; then
    echo "error: MACPAPER_UPDATE_TEST=1 needs OPENAPPS_OFFICIAL=1 (the updater is what it tests)" >&2
    exit 1
fi
if [[ "$UPDATE_TEST" == "1" && "${OPENAPPS_LICENSING:-0}" == "1" ]]; then
    echo "error: MACPAPER_UPDATE_TEST=1 cannot be combined with OPENAPPS_LICENSING=1: the update-test variant must not reach licensing services or register a login item" >&2
    exit 1
fi
if [[ "$UPDATE_TEST" == "1" ]]; then
    BUNDLE_ID="${BUNDLE_ID}.updatetest"
    FEED_URL="${UPDATE_FEED_URL:-$FEED_URL}"
elif [[ -n "${UPDATE_FEED_URL:-}" ]]; then
    echo "error: UPDATE_FEED_URL is accepted only with MACPAPER_UPDATE_TEST=1" >&2
    exit 1
fi

# Version: explicit, else the release tag on HEAD, else a development marker.
if [[ -z "${VERSION:-}" ]]; then
    tag="$(git describe --tags --exact-match --match 'macpaper-v*' 2>/dev/null || true)"
    VERSION="${tag#macpaper-v}"
    VERSION="${VERSION:-0.0.0}"
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must be MAJOR.MINOR.PATCH (got '${VERSION}')" >&2
    exit 1
fi
# CFBundleVersion, derived from the version (RELEASES.md): the updater and
# the feed compare builds, so they must order exactly as releases do.
IFS=. read -r major minor patch <<< "$VERSION"
if (( major > 999 || minor > 999 || patch > 999 )); then
    echo "error: each part of VERSION must be at most 999 (got '${VERSION}')" >&2
    exit 1
fi
BUILD_NUMBER=$(( major * 1000000 + minor * 1000 + patch ))

# Release signing (inside scripts/release/with-signing-keychain.sh, which
# exports both): the requirement is derived from the bundle identifier and
# the certificate, and must be the pinned one, so the wrong certificate fails
# before the build starts.
SIGNING_IDENTITY="${RELEASE_SIGNING_IDENTITY:-}"
SIGNING_KEYCHAIN="${RELEASE_SIGNING_KEYCHAIN:-}"
REQUIREMENT=""
if [[ -n "$SIGNING_IDENTITY" || -n "$SIGNING_KEYCHAIN" ]]; then
    if [[ -z "$SIGNING_IDENTITY" || -z "$SIGNING_KEYCHAIN" ]]; then
        echo "error: set both RELEASE_SIGNING_IDENTITY and RELEASE_SIGNING_KEYCHAIN (scripts/release/with-signing-keychain.sh does), or neither (ad-hoc)" >&2
        exit 1
    fi
    [[ "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "error: RELEASE_SIGNING_IDENTITY must be a certificate SHA-1" >&2; exit 1; }
    test -f "$SIGNING_KEYCHAIN" || { echo "error: keychain ${SIGNING_KEYCHAIN} not found" >&2; exit 1; }
    # The form scripts/release/designated-requirement.sh prints from the certificate.
    REQUIREMENT="identifier \"${BUNDLE_ID}\" and certificate leaf = H\"$(printf '%s' "$SIGNING_IDENTITY" | tr '[:upper:]' '[:lower:]')\""
    if [[ "$UPDATE_TEST" != "1" ]]; then
        pinned="$(tr -d '\r' < release/designated-requirement.txt | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true)"
        if [[ "$pinned" != "$REQUIREMENT" ]]; then
            echo "error: the signing certificate does not give the pinned designated requirement (RELEASING.md, \"Signing certificate and update key\")" >&2
            echo "  pinned:  ${pinned}" >&2
            echo "  derived: ${REQUIREMENT}" >&2
            exit 1
        fi
    fi
fi

# The public update key official builds pin. A release-signed build must use
# the committed one; an ad-hoc build (CI checks) or the update-test variant
# may pin a throwaway key with UPDATE_PUBLIC_ED_KEY.
PUBLIC_ED_KEY=""
if [[ "$OFFICIAL" == "1" ]]; then
    if [[ -n "${UPDATE_PUBLIC_ED_KEY:-}" && -n "$SIGNING_IDENTITY" && "$UPDATE_TEST" != "1" ]]; then
        echo "error: UPDATE_PUBLIC_ED_KEY is accepted only for ad-hoc signed builds; a release pins release/sparkle-public-key.txt" >&2
        exit 1
    fi
    PUBLIC_ED_KEY="${UPDATE_PUBLIC_ED_KEY:-$(head -n 1 release/sparkle-public-key.txt)}"
    if [[ ! "$PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        echo "error: release/sparkle-public-key.txt holds no update key; create one with scripts/create-update-key.sh (RELEASING.md, \"Signing certificate and update key\")" >&2
        exit 1
    fi
    case "$FEED_URL" in
        https://*) ;;
        http://127.0.0.1:*) [[ "$UPDATE_TEST" == "1" ]] || { echo "error: an http feed is only for update tests" >&2; exit 1; } ;;
        *) echo "error: UPDATE_FEED_URL must be https:// (or http://127.0.0.1:<port> for an update test), got '${FEED_URL}'" >&2; exit 1 ;;
    esac
fi

CONFIG_FILE="Sources/MacPaper/Licensing/LicensingConfig.swift"
rm -f "$CONFIG_FILE"
# A local registry or update feed over plain http (test builds only; the
# config generator and the checks above enforce that) needs App Transport
# Security's local-networking exception.
NEEDS_LOCAL_NETWORKING=0
if [[ "${OPENAPPS_LICENSING:-0}" == "1" ]]; then
    scripts/generate-licensing-config.sh "$CONFIG_FILE"
    echo "==> Licensing on (${OPENAPPS_DODO_ENV})"
    if [[ "${OPENAPPS_TRIAL_REGISTRY_BASE_URL:-}" == http://* ]]; then NEEDS_LOCAL_NETWORKING=1; fi
else
    echo "==> Licensing off (source build: no License UI, no trial, no license network calls)"
fi
if [[ "$OFFICIAL" == "1" ]]; then
    echo "==> Updater on (feed ${FEED_URL}; a fresh install checks automatically, downloads stay off until the user turns them on)"
    if [[ "$FEED_URL" == http://* ]]; then NEEDS_LOCAL_NETWORKING=1; fi
else
    echo "==> Updater off (source build: no update checks)"
fi
ATS_PLIST=""
if [[ "$NEEDS_LOCAL_NETWORKING" == 1 ]]; then
    ATS_PLIST="<key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>"
fi
# The website's thanks page opens macpaper://activate?key=… to pre-fill the key;
# a build without licensing registers the scheme too and ignores the link.
# The update-test variant must never catch the real app's links.
URL_TYPES_PLIST=""
if [[ "$UPDATE_TEST" != "1" ]]; then
    URL_TYPES_PLIST="<key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${BUNDLE_ID}.activate</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>macpaper</string>
            </array>
        </dict>
    </array>"
fi
UPDATER_PLIST=""
if [[ "$OFFICIAL" == "1" ]]; then
    UPDATER_PLIST="<key>SUFeedURL</key>
    <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${PUBLIC_ED_KEY}</string>"
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    echo "==> Building universal release binary (${VERSION}, build ${BUILD_NUMBER})"
else
    echo "==> Building release binary (${VERSION}, build ${BUILD_NUMBER})"
fi
export OPENAPPS_LICENSING="${OPENAPPS_LICENSING:-0}"
export OPENAPPS_OFFICIAL="$OFFICIAL"
export MACPAPER_UPDATE_TEST="$UPDATE_TEST"
swift build -c release --scratch-path "$SCRATCH_PATH" --product "$PRODUCT_NAME" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT_NAME" "$APP/Contents/MacOS/$APP_NAME"
# Resources are read from Contents/Resources directly (see AppResources), so
# SwiftPM's resource bundle is not copied.
cp -R Sources/MacPaper/Resources/. "$APP/Contents/Resources/"
cp LICENSE NOTICE "$APP/Contents/Resources/"
test -f "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    ${URL_TYPES_PLIST}
    ${ATS_PLIST}
    ${UPDATER_PLIST}
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. An OpenApps HQ original.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Signing. The release keychain is on the search list only while
# with-signing-keychain.sh runs; this script never changes that list.
if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "==> Signing with the release certificate ${SIGNING_IDENTITY}"
    SIGN=(codesign --force --options runtime --timestamp=none --keychain "$SIGNING_KEYCHAIN" --sign "$SIGNING_IDENTITY")
else
    echo "==> Signing ad-hoc (development build)"
    SIGN=(codesign --force --options runtime --timestamp=none --sign -)
fi
if [[ -n "$REQUIREMENT" ]]; then
    "${SIGN[@]}" --entitlements "$ENTITLEMENTS" -r="designated => ${REQUIREMENT}" "$APP"
else
    "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ -n "$REQUIREMENT" ]]; then
    actual="$(codesign --display -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
    if [[ "$actual" != "$REQUIREMENT" ]]; then
        echo "error: signed with designated requirement '${actual}', expected '${REQUIREMENT}'" >&2
        exit 1
    fi
fi
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    archs="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
    for arch in arm64 x86_64; do
        case " $archs " in
            *" $arch "*) ;;
            *) echo "error: not a universal binary, ${arch} is missing (got '${archs}')" >&2; exit 1 ;;
        esac
    done
fi

echo "==> Done: ${APP} (${VERSION}, build ${BUILD_NUMBER})"
