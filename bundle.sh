#!/bin/bash
# Builds Holoscape and packages it as a proper macOS .app bundle.
# Usage: ./bundle.sh [release|debug]

set -euo pipefail

CONFIG="${1:-debug}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/$CONFIG"
APP_DIR="$SCRIPT_DIR/build/Holoscape.app"

echo "Building Holoscape ($CONFIG)..."
if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo "Assembling Holoscape.app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/Holoscape" "$APP_DIR/Contents/MacOS/Holoscape"

# Copy app icon
cp "$SCRIPT_DIR/Sources/Holoscape/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Copy Info.plist and resolve Xcode variables
sed -e 's/$(EXECUTABLE_NAME)/Holoscape/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.synthinsightlabs.holoscape/g' \
    -e 's/$(PRODUCT_NAME)/Holoscape/g' \
    -e 's/$(MARKETING_VERSION)/3.0/g' \
    -e 's/$(CURRENT_PROJECT_VERSION)/1/g' \
    "$SCRIPT_DIR/Info.plist" > "$APP_DIR/Contents/Info.plist"

echo "Done! App bundle created at: $APP_DIR"
echo ""
echo "To run:  open $APP_DIR"
echo "To install: cp -R $APP_DIR /Applications/"
