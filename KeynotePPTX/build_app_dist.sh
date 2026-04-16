#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="keynotepptx"
CONFIGURATION="Release"
BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
APP_NAME="KeynotePPTX"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

echo "==> Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Writing ExportOptions.plist"
cat > "$EXPORT_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

echo "==> Archiving $SCHEME ($CONFIGURATION) — universal binary (arm64 + x86_64)"
xcodebuild archive \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk macosx \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  | xcpretty 2>/dev/null || cat  # fall back to raw output if xcpretty not installed

echo "==> Exporting .app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH=$(find "$EXPORT_PATH" -name "*.app" -maxdepth 2 | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: No .app found in $EXPORT_PATH" >&2
  exit 1
fi
echo "==> Found app: $APP_PATH"

echo "==> Staging DMG contents"
DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "==> Creating DMG: $DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo ""
echo "Done! Distributable files:"
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"
echo ""
echo "NOTE: This build is not notarized. Users must right-click > Open on first launch,"
echo "      or run: xattr -d com.apple.quarantine \"$APP_NAME.app\""
