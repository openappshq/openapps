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
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenReaction"
BUNDLE_ID="com.openappshq.openreaction"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${APPLE_SIGNING_IDENTITY:--}"
APP="build/${APP_NAME}.app"

echo "==> Building release binary"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

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
