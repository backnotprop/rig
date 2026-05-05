#!/bin/bash
set -euo pipefail

# Rig development build + run script.
# Signs every build with "Rig Local Development" so macOS permissions
# (Accessibility, Input Monitoring) survive across rebuilds.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="Rig"
CONFIG="Debug"
DERIVED_DATA="$PROJECT_DIR/.build"
APP="$DERIVED_DATA/Build/Products/$CONFIG/Rig.app"
SIGN_IDENTITY="Rig Local Development"

# Verify the signing identity exists.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "ERROR: Signing identity '$SIGN_IDENTITY' not found."
    echo ""
    echo "Create it once in Keychain Access:"
    echo "  Keychain Access → Certificate Assistant → Create a Certificate"
    echo "  Name: $SIGN_IDENTITY"
    echo "  Identity Type: Self Signed Root"
    echo "  Certificate Type: Code Signing"
    exit 1
fi

echo "Building Rig (signed with '$SIGN_IDENTITY')..."
xcodebuild \
    -project "$PROJECT_DIR/Rig.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="" \
    build 2>&1 | tail -5

echo ""
echo "Re-signing entire bundle (ensures all nested binaries match)..."
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>&1

echo ""
echo "Verifying signature..."
codesign -dv "$APP" 2>&1 | grep -E "Authority|Identifier|Signature"

echo ""
echo "Killing old instance..."
pkill -x Rig 2>/dev/null || true
sleep 0.5

echo "Launching Rig..."
open "$APP"
