#!/usr/bin/env bash
set -euo pipefail

# meloDL Release Build Script
# Usage: ./scripts/build-release.sh [--notarize]
#
# Prerequisites:
#   - Xcode with "Developer ID Application" certificate installed
#   - For --notarize: app-specific password stored in keychain:
#     xcrun notarytool store-credentials "meloDL-notarize" \
#       --apple-id YOUR_APPLE_ID \
#       --team-id THZ82CJTKM \
#       --password YOUR_APP_SPECIFIC_PASSWORD

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
SCHEME="meloDL"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
APP_PATH="$BUILD_DIR/$SCHEME.app"
DMG_PATH="$BUILD_DIR/$SCHEME.dmg"
DMG_STAGING_DIR="$BUILD_DIR/dmg-staging"
TEAM_ID="THZ82CJTKM"
NOTARIZE=false

if [[ "${1:-}" == "--notarize" ]]; then
    NOTARIZE=true
fi

echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Resolving Swift packages..."
cd "$PROJECT_DIR"
xcodebuild -resolvePackageDependencies \
    -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -quiet

echo "==> Archiving $SCHEME..."
xcodebuild archive \
    -project "$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet

echo "==> Exporting archive (Developer ID)..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$BUILD_DIR" \
    -exportOptionsPlist "$PROJECT_DIR/exportOptions.plist" \
    -quiet

echo "==> Re-signing bundled executables with hardened runtime..."
SIGNING_IDENTITY_HASH="${SIGNING_IDENTITY_HASH:-}"
if [[ -z "$SIGNING_IDENTITY_HASH" ]]; then
    SIGNING_IDENTITY_HASH="$(
        security find-identity -v -p codesigning \
        | grep -E "Developer ID Application: .*\\($TEAM_ID\\)" \
        | awk 'NR==1 {print $2}'
    )"
fi

if [[ -z "$SIGNING_IDENTITY_HASH" ]]; then
    echo "ERROR: Could not find a Developer ID Application signing identity for team $TEAM_ID."
    echo "Set SIGNING_IDENTITY_HASH explicitly if needed."
    exit 1
fi

for binary in ffmpeg ffprobe yt-dlp; do
    binary_path="$APP_PATH/Contents/Resources/$binary"
    if [[ -f "$binary_path" ]]; then
        codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY_HASH" "$binary_path"
    else
        echo "WARNING: Expected bundled binary not found: $binary_path"
    fi
done

codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$SIGNING_IDENTITY_HASH" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Creating DMG..."
# Create a drag-and-drop installer layout.
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_PATH" "$DMG_STAGING_DIR/"

if command -v create-dmg >/dev/null 2>&1; then
    # Let create-dmg create its own Applications link (--app-drop-link).
    create-dmg \
        --volname "$SCHEME" \
        --window-pos 200 120 \
        --window-size 640 400 \
        --icon-size 128 \
        --icon "$SCHEME.app" 170 185 \
        --hide-extension "$SCHEME.app" \
        --app-drop-link 470 185 \
        "$DMG_PATH" \
        "$DMG_STAGING_DIR"
else
    # Fallback: plain DMG with manual Applications symlink.
    ln -s /Applications "$DMG_STAGING_DIR/Applications"
    hdiutil create \
        -volname "$SCHEME" \
        -srcfolder "$DMG_STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

if $NOTARIZE; then
    echo "==> Notarizing DMG..."
    NOTARY_OUTPUT="$(
        xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "meloDL-notarize" \
        --wait
    )"
    printf '%s\n' "$NOTARY_OUTPUT"

    if ! printf '%s\n' "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        echo "ERROR: Notarization was not accepted. Skipping stapling."
        echo "Run: xcrun notarytool log <submission-id> --keychain-profile meloDL-notarize"
        exit 1
    fi

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleVersion)

echo ""
echo "==> Build complete!"
echo "    App:     $APP_PATH"
echo "    DMG:     $DMG_PATH"
echo "    Version: $VERSION ($BUILD)"
echo ""
echo "Next steps:"
echo "  1. Upload $DMG_PATH to GitHub Releases"
echo "  2. Run: sparkle/bin/generate_appcast $BUILD_DIR"
echo "  3. Commit updated appcast.xml to the repo"
