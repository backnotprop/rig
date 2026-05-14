#!/bin/bash
set -euo pipefail

# Rig release build script.
# Builds Release config, signs with Developer ID, notarizes with Apple,
# staples the ticket, and produces a DMG for GitHub Releases.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="Rig"
CONFIG="Release"
DERIVED_DATA="$PROJECT_DIR/.build-release"
APP="$DERIVED_DATA/Build/Products/$CONFIG/Rig.app"
SIGN_IDENTITY="Developer ID Application: Nicholas  Ramos (TX8NWU7D68)"
TEAM_ID="TX8NWU7D68"
NOTARIZE_PROFILE="Rig-Notarize"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>"
    echo "  e.g. ./release.sh 0.1.0"
    exit 1
fi

DMG_NAME="Rig-${VERSION}-mac.dmg"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
STAGING_DIR="$PROJECT_DIR/.dmg-staging"

# Verify signing identity.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "ERROR: Signing identity not found: $SIGN_IDENTITY"
    exit 1
fi

# Verify notarization credentials.
if ! xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: Notarization profile '$NOTARIZE_PROFILE' not found."
    echo ""
    echo "Store credentials with:"
    echo "  xcrun notarytool store-credentials \"$NOTARIZE_PROFILE\" \\"
    echo "    --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
    exit 1
fi

echo "==> Cleaning previous release build..."
rm -rf "$DERIVED_DATA"
rm -f "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "==> Building Rig ($CONFIG)..."
xcodebuild \
    -project "$PROJECT_DIR/Rig.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build 2>&1 | tail -5

echo ""
echo "==> Signing bundle..."
codesign --force --options runtime \
    --entitlements "$PROJECT_DIR/Rig/Rig.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"

echo "==> Verifying signature..."
codesign --verify --verbose=2 "$APP" 2>&1
echo ""
codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier|Signature|Runtime"

echo ""
echo "==> Verifying entitlements..."
if ! codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.automation.apple-events"; then
    echo "ERROR: apple-events entitlement missing from signed app!"
    exit 1
fi
echo "  apple-events entitlement: present"

echo ""
echo "==> Creating DMG..."
mkdir -p "$STAGING_DIR"
cp -R "$APP" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "Rig" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo ""
echo "==> Submitting to Apple for notarization..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

echo ""
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "==> Verifying notarization..."
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" 2>&1

echo ""
echo "============================================"
echo "  Release ready: $DMG_NAME"
echo "  Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "  Upload to GitHub:"
echo "    gh release create v${VERSION} '$DMG_PATH' --title 'v${VERSION}' --notes 'Release v${VERSION}'"
echo "============================================"
