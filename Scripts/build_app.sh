#!/bin/zsh
# Builds "count yo tokens.app" into dist/. Pass --install to replace the copy in /Applications and relaunch.
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="count yo tokens"
BUNDLE_ID="com.sirrayi.countyotokens"
VERSION="1.0.0"
APP="dist/${APP_NAME}.app"

swift build -c release --product CountYoTokens
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CountYoTokens "$APP/Contents/MacOS/CountYoTokens"
strip -x "$APP/Contents/MacOS/CountYoTokens"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>CountYoTokens</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Forked from CodexBar.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x CountYoTokens 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "$APP" "/Applications/${APP_NAME}.app"
    rm -rf dist
    sleep 1
    open "/Applications/${APP_NAME}.app"
    echo "Installed and launched /Applications/${APP_NAME}.app"
fi
