#!/usr/bin/env bash
# Build, sign, package, and optionally notarize LiveAstro Studio for direct macOS distribution.
#
# Default verification never contacts Apple. Notarization happens only when --notarize is explicit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="3.0.3"
SIGN_MODE="ad-hoc"
IDENTITY="${DEVID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARIZE=0
DRY_RUN=0

APP="dist/LiveAstroStudio.app"
BUNDLE_NAME="LiveAstroStudio_LiveAstroStudio.bundle"
ENTITLEMENTS="Scripts/LiveAstroStudio.entitlements"
BUNDLE_ID="com.pauldavis.liveastrostudio"
SCRATCH="/private/tmp/liveastro-release-build"

usage() {
    cat <<'USAGE'
Usage:
  Scripts/package_release.sh [options]

Options:
  --version VERSION             App/DMG version. Default: 3.0.3
  --sign ad-hoc|developer-id    Signing mode. Default: ad-hoc
  --identity IDENTITY           Developer ID Application identity. May also use DEVID.
  --notarize                    Submit the DMG to Apple notarization and staple the ticket.
  --notary-profile PROFILE      notarytool keychain profile. May also use NOTARY_PROFILE.
  --dry-run                     Validate options and print the selected plan without building.
  -h, --help                    Show this help.

Examples:
  Scripts/package_release.sh --version 3.0.3 --sign ad-hoc
  Scripts/package_release.sh --version 3.0.3 --sign developer-id \
      --identity "Developer ID Application: Name (TEAMID)"
  Scripts/package_release.sh --version 3.0.3 --sign developer-id \
      --identity "Developer ID Application: Name (TEAMID)" \
      --notarize --notary-profile liveastro-notary
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --sign)
            [ "$#" -ge 2 ] || fail "--sign requires ad-hoc or developer-id"
            SIGN_MODE="$2"
            shift 2
            ;;
        --identity)
            [ "$#" -ge 2 ] || fail "--identity requires a value"
            IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            [ "$#" -ge 2 ] || fail "--notary-profile requires a value"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --notarize)
            NOTARIZE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

case "$SIGN_MODE" in
    ad-hoc|developer-id) ;;
    *) fail "--sign must be ad-hoc or developer-id" ;;
esac

if [ "$SIGN_MODE" = "developer-id" ] && [ -z "$IDENTITY" ]; then
    fail "Developer ID signing requires --identity or DEVID"
fi

if [ "$NOTARIZE" -eq 1 ] && [ "$SIGN_MODE" != "developer-id" ]; then
    fail "--notarize requires --sign developer-id"
fi

if [ "$NOTARIZE" -eq 1 ] && [ -z "$NOTARY_PROFILE" ]; then
    fail "--notarize requires --notary-profile or NOTARY_PROFILE"
fi

DMG="dist/LiveAstroStudio-$VERSION.dmg"

print_plan() {
    echo "LiveAstro release package plan"
    echo "  version:          $VERSION"
    echo "  sign mode:        $SIGN_MODE"
    if [ "$SIGN_MODE" = "developer-id" ]; then
        echo "  identity:         $IDENTITY"
    else
        echo "  identity:         ad-hoc (-)"
    fi
    if [ "$NOTARIZE" -eq 1 ]; then
        echo "  notarize:         yes"
        echo "  notary profile:   $NOTARY_PROFILE"
    else
        echo "  notarize:         no"
    fi
    echo "  app:              $APP"
    echo "  dmg:              $DMG"
}

print_plan

if [ "$DRY_RUN" -eq 1 ]; then
    exit 0
fi

echo "== universal release build (arm64 + x86_64) =="
rm -rf "$SCRATCH"
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"

if [ -d "$SCRATCH/apple/Products/Release" ]; then
    PROD="$SCRATCH/apple/Products/Release"
else
    PROD="$SCRATCH/release"
fi

BIN="$PROD/LiveAstroStudio"
BUNDLE_SRC="$PROD/$BUNDLE_NAME"

[ -f "$BIN" ] || fail "built binary not found at $BIN"
[ -d "$BUNDLE_SRC" ] || fail "resource bundle not found at $BUNDLE_SRC"

if command -v lipo >/dev/null 2>&1; then
    echo "   arch: $(lipo -archs "$BIN")"
fi

echo "== assemble $APP =="
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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

# Older SwiftPM versions emitted the resource bundle flat. Current SwiftPM emits
# a conventional bundle with Contents/Info.plist. Only apply the old flat-bundle
# workaround when the built bundle lacks a structured Info.plist; adding a root
# Info.plist to a structured bundle makes codesign reject "unsealed contents".
if [ ! -f "$APP/Contents/MacOS/$BUNDLE_NAME/Contents/Info.plist" ]; then
    cat > "$APP/Contents/MacOS/$BUNDLE_NAME/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.resources</string>
  <key>CFBundleName</key><string>LiveAstroStudio_LiveAstroStudio</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
fi

xattr -cr "$APP"

echo "== sign inside-out =="
if [ "$SIGN_MODE" = "ad-hoc" ]; then
    SIGN=(codesign --force --options runtime --sign -)
else
    SIGN=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
fi

"${SIGN[@]}" "$APP/Contents/MacOS/$BUNDLE_NAME"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/LiveAstroStudio"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"

echo "== verify signature =="
codesign --verify --strict --verbose=2 "$APP"

if [ "$SIGN_MODE" = "developer-id" ]; then
    spctl -a -vv --type execute "$APP" 2>&1 || echo "   Gatekeeper may reject until notarization is stapled."
else
    echo "   ad-hoc signed build: Gatekeeper acceptance is not expected."
fi

echo "== build DMG =="
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "LiveAstro Studio" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "   wrote $DMG"

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "== sign DMG =="
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

if [ "$NOTARIZE" -eq 0 ]; then
    if [ "$SIGN_MODE" = "developer-id" ]; then
        echo "== Developer ID signed but not notarized =="
        echo "   Re-run with --notarize --notary-profile <profile> for public distribution."
    else
        echo "== ad-hoc signed local package =="
        echo "   This is for local testing only, not public distribution."
    fi
    echo "done: $DMG"
    exit 0
fi

echo "== notarize DMG with notarytool =="
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== staple app ticket =="
xcrun stapler staple "$APP"

echo "== rebuild DMG with stapled app =="
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "LiveAstro Studio" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "== sign DMG with stapled app =="
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

echo "== notarize DMG with notarytool =="
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== staple DMG ticket =="
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "== final Gatekeeper check =="
spctl -a -vv --type execute "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG"
echo "done: notarized + stapled → $DMG"
