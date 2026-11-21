#!/bin/zsh
# Builds "count yo tokens.app" into dist/.
#   --install  replace the copy in /Applications and relaunch it
#   --zip      build for Apple silicon and Intel, and zip the app for a GitHub release
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="count yo tokens"
BUNDLE_ID="com.sirrayi.countyotokens"
VERSION="1.0.0"
APP="dist/${APP_NAME}.app"

if [[ "${1:-}" == "--zip" ]]; then
    swift build -c release --product CountYoTokens --arch arm64 --arch x86_64
    BINARY=.build/apple/Products/Release/CountYoTokens
else
    swift build -c release --product CountYoTokens
    BINARY=.build/release/CountYoTokens
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/CountYoTokens"
strip -x "$APP/Contents/MacOS/CountYoTokens"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>CountYoTokens</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 sirrayi. MIT License.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--zip" ]]; then
    ZIP="dist/count-yo-tokens-${VERSION}.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Zipped $ZIP ($(du -sh "$ZIP" | cut -f1)), $(lipo -archs "$APP/Contents/MacOS/CountYoTokens")"
fi

if [[ "${1:-}" == "--install" ]]; then
    pkill -x CountYoTokens 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "$APP" "/Applications/${APP_NAME}.app"
    rm -rf dist
    sleep 1
    open "/Applications/${APP_NAME}.app"
    echo "Installed and launched /Applications/${APP_NAME}.app"
fi
