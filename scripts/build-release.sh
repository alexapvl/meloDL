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

echo "==> Creating DMG..."
hdiutil create \
    -volname "$SCHEME" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if $NOTARIZE; then
    echo "==> Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "meloDL-notarize" \
        --wait

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
