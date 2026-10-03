#!/usr/bin/env bash
# Build and Developer-ID-sign a local sandbox preview. This never notarizes,
# uploads, installs into /Applications, or modifies the direct-release output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="3.6.11"
IDENTITY="${DEVID:-}"
OUTPUT_APP="$ROOT/.build/store-preview/LiveAstro Store Preview.app"
SCRATCH_ROOT="${TMPDIR:-/private/tmp}"
BUNDLE_ID="com.pauldavis.liveastrostudio.store-preview"
DISPLAY_NAME="LiveAstro Store Preview"
BUNDLE_NAME="LiveAstroStudio_LiveAstroStudio.bundle"
ENTITLEMENTS="$ROOT/Scripts/StorePreview.entitlements"

usage() {
    cat <<'USAGE'
Usage:
  Scripts/package_store_preview.sh --identity IDENTITY [options]

Options:
  --identity IDENTITY    Existing Developer ID Application identity. May also use DEVID.
  --version VERSION      CFBundleShortVersionString. Default: 3.6.11
  --output-app PATH      New development .app path. The path must not already exist.
  --scratch-root PATH    Existing directory in which the script creates its own mktemp scratch.
  -h, --help             Show this help.

This command creates a local signed sandbox preview only. It does not launch,
install, notarize, upload, or alter dist/ and never replaces an existing app.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --identity)
            [ "$#" -ge 2 ] || fail "--identity requires a value"
            IDENTITY="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --output-app)
            [ "$#" -ge 2 ] || fail "--output-app requires a value"
            OUTPUT_APP="$2"
            shift 2
            ;;
        --scratch-root)
            [ "$#" -ge 2 ] || fail "--scratch-root requires a value"
            SCRATCH_ROOT="$2"
            shift 2
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

# Validate the complete plan before invoking mktemp, Swift, or any signing tool.
[ -n "$IDENTITY" ] || fail "an existing Developer ID Application identity is required via --identity or DEVID"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || fail "--version must contain non-empty dot-separated decimal components"
case "$OUTPUT_APP" in
    /*.app) ;;
    *) fail "--output-app must be an absolute path ending in .app" ;;
esac
case "$OUTPUT_APP" in
    */../*|*/./*) fail "--output-app may not contain . or .. path components" ;;
esac
case "$SCRATCH_ROOT" in
    /*) ;;
    *) fail "--scratch-root must be an absolute path" ;;
esac
[ -d "$SCRATCH_ROOT" ] || fail "scratch root does not exist: $SCRATCH_ROOT"
[ -w "$SCRATCH_ROOT" ] || fail "scratch root is not writable: $SCRATCH_ROOT"
[ -f "$ENTITLEMENTS" ] || fail "entitlements file not found: $ENTITLEMENTS"
if [ -e "$OUTPUT_APP" ] || [ -L "$OUTPUT_APP" ]; then
    fail "output already exists; preserving it: $OUTPUT_APP"
fi

# Resolve the nearest existing output ancestor so a symlink cannot redirect a
# seemingly safe development path into /Applications. Missing descendants are
# appended only after the existing ancestor has been physically resolved.
canonical_future_directory() {
    local candidate="$1"
    local suffix=""
    local component parent resolved
    while [ ! -e "$candidate" ]; do
        component="$(basename "$candidate")"
        suffix="/$component$suffix"
        parent="$(dirname "$candidate")"
        [ "$parent" != "$candidate" ] || return 1
        candidate="$parent"
    done
    [ -d "$candidate" ] || return 1
    resolved="$(cd "$candidate" && pwd -P)"
    printf '%s%s\n' "$resolved" "$suffix"
}

OUTPUT_PARENT="$(dirname "$OUTPUT_APP")"
CANONICAL_OUTPUT_PARENT="$(canonical_future_directory "$OUTPUT_PARENT")" \
    || fail "cannot resolve output parent: $OUTPUT_PARENT"
case "$CANONICAL_OUTPUT_PARENT" in
    /Applications|/Applications/*) fail "the preview may not be written under /Applications" ;;
esac

SCRATCH=""
PUBLISH_APP=""
cleanup() {
    if [ -n "$PUBLISH_APP" ] && [ -d "$PUBLISH_APP" ]; then
        rm -rf -- "$PUBLISH_APP"
    fi
    if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
        rm -rf -- "$SCRATCH"
    fi
}
trap cleanup EXIT

SCRATCH="$(mktemp -d "${SCRATCH_ROOT%/}/liveastro-store-preview.XXXXXX")"
STAGED_APP="$SCRATCH/$DISPLAY_NAME.app"

echo "== build universal Store Preview in owned scratch =="
cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"

if [ -d "$SCRATCH/apple/Products/Release" ]; then
    PRODUCT="$SCRATCH/apple/Products/Release"
else
    PRODUCT="$SCRATCH/release"
fi
BUILT_BINARY="$PRODUCT/LiveAstroStudio"
BUILT_RESOURCES="$PRODUCT/$BUNDLE_NAME"
[ -f "$BUILT_BINARY" ] || fail "built binary not found at $BUILT_BINARY"
[ -d "$BUILT_RESOURCES" ] || fail "resource bundle not found at $BUILT_RESOURCES"

echo "== assemble isolated preview bundle =="
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
ditto --norsrc --noextattr "$BUILT_BINARY" "$STAGED_APP/Contents/MacOS/LiveAstroStudio"
ditto --norsrc --noextattr "$BUILT_RESOURCES" "$STAGED_APP/Contents/Resources/$BUNDLE_NAME"

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>LiveAstroStudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# SwiftPM historically emitted both flat and structured resource bundles.
if [ ! -f "$STAGED_APP/Contents/Resources/$BUNDLE_NAME/Contents/Info.plist" ]; then
    cat > "$STAGED_APP/Contents/Resources/$BUNDLE_NAME/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.resources</string>
  <key>CFBundleName</key><string>LiveAstroStudio_LiveAstroStudio</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
fi

[ -d "$STAGED_APP/Contents/Resources/$BUNDLE_NAME" ] || fail "resource bundle was not packaged under Contents/Resources"
[ ! -d "$STAGED_APP/Contents/MacOS/$BUNDLE_NAME" ] || fail "resource bundle was incorrectly packaged under Contents/MacOS"
xattr -cr "$STAGED_APP"

echo "== Developer ID sign local preview (no notarization) =="
SIGN=(codesign --force --options runtime --timestamp=none --sign "$IDENTITY")
"${SIGN[@]}" "$STAGED_APP/Contents/Resources/$BUNDLE_NAME"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$STAGED_APP/Contents/MacOS/LiveAstroStudio"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

# Copy to an owned temporary sibling on the destination filesystem. Nothing is
# visible at the final path until this copy has passed every verification.
mkdir -p "$OUTPUT_PARENT"
if [ -e "$OUTPUT_APP" ] || [ -L "$OUTPUT_APP" ]; then
    fail "output appeared while packaging; preserving it: $OUTPUT_APP"
fi
PUBLISH_APP="$(mktemp -d "$OUTPUT_PARENT/.${DISPLAY_NAME}.app.publish.XXXXXX")"
ditto --norsrc --noextattr "$STAGED_APP/" "$PUBLISH_APP/"
# ditto copies the contents into the existing mktemp directory, whose 0700
# mode would otherwise survive publication. Keep the staged bundle root mode.
chmod "$(stat -f '%Lp' "$STAGED_APP")" "$PUBLISH_APP"

echo "== verify destination copy before publication =="
codesign --verify --deep --strict "$PUBLISH_APP"
SIGNED_INFO="$(codesign -dv --verbose=4 "$PUBLISH_APP" 2>&1)"
SIGNED_IDENTIFIER="$(printf '%s\n' "$SIGNED_INFO" | sed -n 's/^Identifier=//p')"
SIGNED_AUTHORITY="$(printf '%s\n' "$SIGNED_INFO" | sed -n 's/^Authority=//p' | sed -n '1p')"
[ "$SIGNED_IDENTIFIER" = "$BUNDLE_ID" ] || fail "signed identifier mismatch: $SIGNED_IDENTIFIER"
case "$SIGNED_AUTHORITY" in
    "Developer ID Application: "*) ;;
    *) fail "unexpected signing authority: $SIGNED_AUTHORITY" ;;
esac

ACTUAL_ENTITLEMENTS="$SCRATCH/signed-entitlements.plist"
codesign -d --entitlements - --xml "$PUBLISH_APP" > "$ACTUAL_ENTITLEMENTS"
for key in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.network.client
do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ACTUAL_ENTITLEMENTS")"
    [ "$value" = "true" ] || fail "signed entitlement is not enabled: $key"
done

PLIST_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$PUBLISH_APP/Contents/Info.plist")"
PLIST_NAME="$(plutil -extract CFBundleDisplayName raw -o - "$PUBLISH_APP/Contents/Info.plist")"
[ "$PLIST_IDENTIFIER" = "$BUNDLE_ID" ] || fail "bundle identifier mismatch: $PLIST_IDENTIFIER"
[ "$PLIST_NAME" = "$DISPLAY_NAME" ] || fail "bundle display name mismatch: $PLIST_NAME"

# Plain mv is unsafe here: if the destination appears concurrently as a
# directory, mv nests the app inside it. renamex_np(RENAME_EXCL) is an atomic,
# same-filesystem no-replace publication primitive on supported macOS releases.
PUBLISH_HELPER="$SCRATCH/publish-exclusive"
xcrun clang -x c -std=c11 -Wall -Wextra -Werror -o "$PUBLISH_HELPER" - <<'C'
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "exclusive publisher requires source and destination\n");
        return 64;
    }
    if (renamex_np(argv[1], argv[2], RENAME_EXCL) == 0) {
        return 0;
    }
    int error = errno;
    fprintf(stderr, "exclusive publish failed: %s\n", strerror(error));
    return error == EEXIST ? 3 : 1;
}
C

echo "== atomically publish verified preview =="
"$PUBLISH_HELPER" "$PUBLISH_APP" "$OUTPUT_APP"
PUBLISH_APP=""

echo "   bundle id: $SIGNED_IDENTIFIER"
echo "   name:      $PLIST_NAME"
echo "   authority: $SIGNED_AUTHORITY"
echo "   sandbox entitlements: parsed and enabled"
echo "done: $OUTPUT_APP"
echo "Local static signing proof only; the app was not launched or notarized."
