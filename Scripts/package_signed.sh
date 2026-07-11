#!/bin/bash
# Build, sign (Developer ID + Hardened Runtime), and optionally notarize+staple
# a distributable LiveAstro Studio .app and .dmg.
#
# This is the NON-App-Store path: notarized Developer ID direct distribution.
# It preserves every feature (GraXpert subprocess, /Volumes SMB scan) that the
# App Store sandbox would break.
#
# ── ONE-TIME SETUP (yours — needs your Apple ID + $99 enrollment) ──────────────
#   1. Enroll in the Apple Developer Program.
#   2. In Xcode ▸ Settings ▸ Accounts, or on developer.apple.com, create a
#      "Developer ID Application" certificate; it installs into your login keychain.
#   3. Find its identity string:
#          security find-identity -v -p codesigning
#      → export DEVID="Developer ID Application: Your Name (TEAMID)"
#   4. Create a notarization credential (app-specific password from appleid.apple.com):
#          xcrun notarytool store-credentials LAS_NOTARY \
#              --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#      → export NOTARY_PROFILE=LAS_NOTARY   (omit to sign only, skip notarize)
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   DEVID="Developer ID Application: ... (TEAMID)" NOTARY_PROFILE=LAS_NOTARY \
#       Scripts/package_signed.sh 2.3.0
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-2.2.0}"
APP="dist/LiveAstroStudio.app"
DMG="dist/LiveAstroStudio-$VERSION.dmg"
BUNDLE_NAME="LiveAstroStudio_LiveAstroStudio.bundle"
ENTITLEMENTS="Scripts/LiveAstroStudio.entitlements"
SCRATCH="/private/tmp/las-release-build"
BUNDLE_ID="com.pauldavis.liveastrostudio"

: "${DEVID:?Set DEVID to your 'Developer ID Application: Name (TEAMID)' identity. Run: security find-identity -v -p codesigning}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"   # empty = sign only, skip notarization

echo "== universal release build (arm64 + x86_64) =="
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"

# Universal build products land under apple/Products/Release; single-arch under release/.
if [ -d "$SCRATCH/apple/Products/Release" ]; then PROD="$SCRATCH/apple/Products/Release"; else PROD="$SCRATCH/release"; fi
BIN="$PROD/LiveAstroStudio"
BUNDLE_SRC="$PROD/$BUNDLE_NAME"
[ -f "$BIN" ] || { echo "ERROR: built binary not found at $BIN"; exit 1; }
[ -d "$BUNDLE_SRC" ] || { echo "ERROR: resource bundle not found at $BUNDLE_SRC"; exit 1; }
echo "   arch: $(lipo -archs "$BIN")"

echo "== assemble $APP =="
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN" "$APP/Contents/MacOS/LiveAstroStudio"
ditto --norsrc --noextattr "$BUNDLE_SRC" "$APP/Contents/MacOS/$BUNDLE_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiveAstro Studio</string>
    <key>CFBundleDisplayName</key><string>LiveAstro Studio</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
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

# SwiftPM emits the resource bundle "flat" (resources at root, no Info.plist),
# which codesign rejects as "bundle format unrecognized". Inject a minimal
# Info.plist so it is a signable bundle. It stays a flat bundle (no Contents/),
# so Bundle.module still resolves Help.md at the bundle root.
cat > "$APP/Contents/MacOS/$BUNDLE_NAME/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.resources</string>
  <key>CFBundleName</key><string>LiveAstroStudio_LiveAstroStudio</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST

# Strip any resource forks / xattrs that trip codesign.
xattr -cr "$APP"

echo "== sign inside-out (NOT --deep; --deep chokes on the resource bundle) =="
SIGN=(codesign --force --timestamp --options runtime --sign "$DEVID")
# 1. nested resource bundle first
"${SIGN[@]}" "$APP/Contents/MacOS/$BUNDLE_NAME"
# 2. main executable (with entitlements)
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/LiveAstroStudio"
# 3. outer app last (seals everything)
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"

echo "== verify signature =="
codesign --verify --strict --verbose=2 "$APP"
# Gatekeeper assessment fails until notarization+staple; harmless to show pre-notarize.
spctl -a -vv --type execute "$APP" 2>&1 || echo "   (spctl reject is expected until notarized+stapled)"

echo "== build DMG =="
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "LiveAstro Studio" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "   wrote $DMG"

if [ -z "$NOTARY_PROFILE" ]; then
  echo "== signed but NOT notarized (NOTARY_PROFILE unset) =="
  echo "   Set NOTARY_PROFILE to notarize + staple. Done: $DMG (signed)."
  exit 0
fi

echo "== notarize (submit DMG, wait) =="
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== staple ticket to app + dmg =="
xcrun stapler staple "$APP"
# Re-pack the DMG so the stapled .app is the one shipped.
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "LiveAstro Studio" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
xcrun stapler staple "$DMG"

echo "== final Gatekeeper check (should ACCEPT) =="
spctl -a -vv --type execute "$APP"
echo "done: notarized + stapled → $DMG"
