#!/usr/bin/env bash
# Build a signed Mac App Store upload package in an owned scratch directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="3.6.12"
APP_IDENTITY="${APPSTORE_APP_IDENTITY:-}"
INSTALLER_IDENTITY="${APPSTORE_INSTALLER_IDENTITY:-}"
OUTPUT_PKG="$ROOT/.build/app-store/LiveAstroStudio.pkg"
APP_BUNDLE_ID="com.pauldavis.liveastrostudio.appstore"
APP_NAME="LiveAstro Studio"
BUNDLE_NAME="LiveAstroStudio_LiveAstroStudio.bundle"
ENTITLEMENTS="$ROOT/Scripts/AppStore.entitlements"

usage() {
    cat <<'USAGE'
Usage: Scripts/package_app_store.sh --identity APP_IDENTITY --installer-identity INSTALLER_IDENTITY [options]
  --version VERSION       App version (default: 3.6.12)
  --identity IDENTITY     Mac App Store application-signing identity
  --installer-identity IDENTITY  Mac App Store installer-signing identity
  --output PATH           New absolute .pkg path
USAGE
}
fail() { echo "ERROR: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || fail "--version requires a value"; VERSION="$2"; shift 2 ;;
        --identity) [ "$#" -ge 2 ] || fail "--identity requires a value"; APP_IDENTITY="$2"; shift 2 ;;
        --installer-identity) [ "$#" -ge 2 ] || fail "--installer-identity requires a value"; INSTALLER_IDENTITY="$2"; shift 2 ;;
        --output) [ "$#" -ge 2 ] || fail "--output requires a value"; OUTPUT_PKG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[ -n "$APP_IDENTITY" ] || fail "application identity is required via --identity or APPSTORE_APP_IDENTITY"
[ -n "$INSTALLER_IDENTITY" ] || fail "installer identity is required via --installer-identity or APPSTORE_INSTALLER_IDENTITY"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "--version must contain dot-separated decimal components"
case "$OUTPUT_PKG" in /*.pkg) ;; *) fail "--output must be an absolute path ending in .pkg" ;; esac
[ ! -e "$OUTPUT_PKG" ] || fail "output already exists; preserving it: $OUTPUT_PKG"
[ -f "$ENTITLEMENTS" ] || fail "missing entitlements: $ENTITLEMENTS"

BUILD_ROOT="$(mktemp -d /private/tmp/liveastro-app-store.XXXXXX)"
APP="$BUILD_ROOT/$APP_NAME.app"
cleanup() { rm -rf -- "$BUILD_ROOT"; }
trap cleanup EXIT

cd "$ROOT"
echo "== build universal App Store binary =="
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$BUILD_ROOT/swift"
if [ -d "$BUILD_ROOT/swift/apple/Products/Release" ]; then PRODUCT="$BUILD_ROOT/swift/apple/Products/Release"; else PRODUCT="$BUILD_ROOT/swift/release"; fi
BIN="$PRODUCT/LiveAstroStudio"
RESOURCES="$PRODUCT/$BUNDLE_NAME"
[ -f "$BIN" ] || fail "built binary not found: $BIN"
[ -d "$RESOURCES" ] || fail "resource bundle not found: $RESOURCES"

echo "== assemble sandboxed App Store bundle =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$BIN" "$APP/Contents/MacOS/LiveAstroStudio"
ditto --norsrc --noextattr "$RESOURCES" "$APP/Contents/Resources/$BUNDLE_NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$APP_BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>LiveAstroStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
[ -f "$APP/Contents/Resources/$BUNDLE_NAME/Contents/Info.plist" ] || fail "resource bundle lacks structured Contents/Info.plist"
xattr -cr "$APP"

echo "== sign App Store bundle =="
codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" "$APP/Contents/Resources/$BUNDLE_NAME"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP/Contents/MacOS/LiveAstroStudio"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

SIGNED_ENTITLEMENTS="$BUILD_ROOT/signed-entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
python3 - "$SIGNED_ENTITLEMENTS" <<'PY'
import plistlib, sys
actual = plistlib.load(open(sys.argv[1], "rb"))
expected = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.files.bookmarks.app-scope": True,
    "com.apple.security.network.client": True,
}
if actual != expected:
    raise SystemExit(f"unexpected entitlement set: {actual!r}")
PY
[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "$APP_BUNDLE_ID" ] || fail "unexpected bundle identifier"

mkdir -p "$(dirname "$OUTPUT_PKG")"
echo "== build signed installer package =="
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$OUTPUT_PKG"
pkgutil --check-signature "$OUTPUT_PKG"
echo "done: $OUTPUT_PKG"
