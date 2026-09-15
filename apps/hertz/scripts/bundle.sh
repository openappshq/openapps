#!/usr/bin/env bash
# Builds a release binary and assembles a signed build/Hertz.app.
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
# Without them the app is ad-hoc signed. Hertz asks for no permissions, so an
# ad-hoc development build loses nothing between rebuilds; the stable
# certificate is what lets `brew upgrade` replace the app in place without
# macOS treating it as a different app.
#
# Environment:
#
#   VERSION       CFBundleShortVersionString, MAJOR.MINOR.PATCH. Defaults to
#                 the `hertz-vX.Y.Z` tag on HEAD, else 0.0.0 (a development
#                 build; official releases always come from a tag).
#   BUILD_NUMBER  CFBundleVersion. Defaults to the commit count on HEAD, so it
#                 only ever grows along the main branch.
#   UNIVERSAL=1   Build one arm64 + x86_64 binary (the release configuration).
#                 Default: the host architecture only.
#   SCRATCH_PATH  SwiftPM's scratch path (default .build).
#
# Signing uses the hardened runtime, no sandbox (libproc, IOKit and the SMC
# user client are unavailable to a sandboxed process) and
# scripts/Hertz.entitlements. There is no in-app updater: updates come from
# Homebrew (RELEASES.md).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Hertz"
BUNDLE_ID="com.openappshq.hertz"
APP="build/${APP_NAME}.app"
ENTITLEMENTS="scripts/${APP_NAME}.entitlements"
SCRATCH_PATH="${SCRATCH_PATH:-.build}"

# Version: explicit, else the release tag on HEAD, else a development marker.
if [[ -z "${VERSION:-}" ]]; then
    tag="$(git describe --tags --exact-match --match 'hertz-v*' 2>/dev/null || true)"
    VERSION="${tag#hertz-v}"
    VERSION="${VERSION:-0.0.0}"
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must be MAJOR.MINOR.PATCH (got '${VERSION}')" >&2
    exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "error: BUILD_NUMBER must be an integer (got '${BUILD_NUMBER}')" >&2
    exit 1
fi

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
    pinned="$(tr -d '\r' < release/designated-requirement.txt | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true)"
    if [[ "$pinned" != "$REQUIREMENT" ]]; then
        echo "error: the signing certificate does not give the pinned designated requirement (RELEASING.md, \"Signing certificate\")" >&2
        echo "  pinned:  ${pinned}" >&2
        echo "  derived: ${REQUIREMENT}" >&2
        exit 1
    fi
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    echo "==> Building universal release binary (${VERSION}, build ${BUILD_NUMBER})"
else
    echo "==> Building release binary (${VERSION}, build ${BUILD_NUMBER})"
fi
swift build -c release --scratch-path "$SCRATCH_PATH" --product "$APP_NAME" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# Resources are read from Contents/Resources directly (see AppResources), so
# SwiftPM's resource bundle is not copied.
cp -R Sources/Hertz/Resources/. "$APP/Contents/Resources/"
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
