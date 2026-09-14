#!/usr/bin/env bash
# Builds a release binary and assembles a signed build/OpenReaction.app.
#
#   scripts/bundle.sh
#   APPLE_SIGNING_IDENTITY="Apple Development: Name (TEAMID)" scripts/bundle.sh
#
# Without APPLE_SIGNING_IDENTITY the app is ad-hoc signed. macOS ties
# Accessibility and Input Monitoring grants to the code signature, and an
# ad-hoc signature changes on every build, so expect to grant permissions
# again after each ad-hoc rebuild. A stable identity avoids that.
#
# Licensing (LICENSING.md) is compiled out by default. Official builds opt in:
#
#   OPENAPPS_LICENSING=1 OPENAPPS_DODO_ENV=test \
#   OPENAPPS_DODO_PAID_PRODUCT_ID=pdt_… OPENAPPS_DODO_TRIAL_PRODUCT_ID=pdt_… \
#   scripts/bundle.sh
#
# OPENAPPS_DODO_ENV is `test` (test.dodopayments.com) or `live`. Optional:
# OPENAPPS_BUY_URL, OPENAPPS_TRIAL_URL, OPENAPPS_SUPPORT_URL — the live
# checkout links, whose redirect_url is the website's return page (paid
# https://openapps.space/openreaction/thanks/, trial
# https://openapps.space/openreaction/thanks/trial/, which deep-links the
# key back into the app):
#
#   OPENAPPS_BUY_URL='https://checkout.dodopayments.com/buy/pdt_0NnbAzI0N8T63rCLtnBxv?quantity=1&redirect_url=https://openapps.space/openreaction/thanks/'
#   OPENAPPS_TRIAL_URL='https://checkout.dodopayments.com/buy/pdt_0NnbAzM7iVdlBBksxe0s4?quantity=1&redirect_url=https://openapps.space/openreaction/thanks/trial/'
#
# The script generates Sources/OpenReaction/Licensing/LicensingConfig.swift
# (gitignored) and refuses to build a licensed app without product IDs.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenReaction"
BUNDLE_ID="com.openappshq.openreaction"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${APPLE_SIGNING_IDENTITY:--}"
APP="build/${APP_NAME}.app"

CONFIG_FILE="Sources/OpenReaction/Licensing/LicensingConfig.swift"
rm -f "$CONFIG_FILE"
if [[ "${OPENAPPS_LICENSING:-0}" == "1" ]]; then
    scripts/generate-licensing-config.sh "$CONFIG_FILE"
    echo "==> Licensing on (${OPENAPPS_DODO_ENV})"
else
    echo "==> Licensing off (source build: no License UI, no license network calls)"
fi

echo "==> Building release binary"
OPENAPPS_LICENSING="${OPENAPPS_LICENSING:-0}" swift build -c release --product "$APP_NAME"
BIN_DIR="$(OPENAPPS_LICENSING="${OPENAPPS_LICENSING:-0}" swift build -c release --show-bin-path)"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# Resources are read from Contents/Resources directly (see AppResources and
# EmojiDatabase.bundled), so SwiftPM's resource bundles are not copied.
cp -R Sources/OpenReaction/Resources/. "$APP/Contents/Resources/"
cp Sources/OpenReactionCore/Resources/emoji.json "$APP/Contents/Resources/emoji.json"
cp LICENSE NOTICE "$APP/Contents/Resources/"

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
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. An OpenApps HQ original.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${BUNDLE_ID}.activate</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>openreaction</string>
            </array>
        </dict>
    </array>
    <!-- Informational. macOS does not show custom text in the Accessibility
         or Input Monitoring prompts; the onboarding window explains both. -->
    <key>NSAccessibilityUsageDescription</key>
    <string>OpenReaction finds the text cursor to show emoji suggestions beside it and types the emoji you choose.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>OpenReaction notices when you type a colon and a shortcode so it can suggest emoji. Typing is matched on this Mac and never saved or sent.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing with identity: ${IDENTITY}"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Done: ${APP}"
