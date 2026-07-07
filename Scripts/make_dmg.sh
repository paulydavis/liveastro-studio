#!/bin/bash
# Builds an UNSIGNED distributable DMG: release binary -> minimal .app bundle -> DMG.
# Friends installing it: drag to /Applications, then right-click -> Open the first
# time (unsigned apps are blocked by plain double-click on modern macOS).
# Signing/notarization (Apple Developer account) is a later step.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.1.0}"
APP=dist/LiveAstroStudio.app
DMG="dist/LiveAstroStudio-$VERSION.dmg"

echo "== release build =="
swift build -c release

echo "== assemble $APP =="
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiveAstroStudio "$APP/Contents/MacOS/LiveAstroStudio"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiveAstro Studio</string>
    <key>CFBundleDisplayName</key><string>LiveAstro Studio</string>
    <key>CFBundleIdentifier</key><string>com.pauldavis.liveastrostudio</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>LiveAstroStudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "== create DMG =="
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "LiveAstro Studio" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "done: $DMG"
