#!/bin/zsh
# Builds "count yo tokens.app" into dist/.
#   --install  replace the copy in /Applications and relaunch it
#   --dmg      build for Apple silicon and Intel, and make the release disk image (needs uv)
#   --zip      build for Apple silicon and Intel, and zip the app
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="count yo tokens"
BUNDLE_ID="com.sirrayi.countyotokens"
VERSION="1.0.2"
APP="dist/${APP_NAME}.app"

if [[ "${1:-}" == "--zip" || "${1:-}" == "--dmg" ]]; then
    ARCHS=(--arch arm64 --arch x86_64)
    swift build -c release --product CountYoTokens $ARCHS
    BINARY="$(swift build -c release --product CountYoTokens $ARCHS --show-bin-path)/CountYoTokens"
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

if [[ "${1:-}" == "--dmg" ]]; then
    DMG="dist/count-yo-tokens-${VERSION}.dmg"
    art=$(mktemp -d)
    trap 'rm -rf "${art:?}"' EXIT
    swift Scripts/make_dmg_background.swift "$art/background.png" 1
    swift Scripts/make_dmg_background.swift "$art/background@2x.png" 2
    rm -f "$DMG"
    uvx --from dmgbuild==1.6.7 dmgbuild -s Scripts/dmg_settings.py \
        -D app="$PWD/$APP" -D icon="$PWD/Assets/AppIcon.icns" -D background="$art/background.png" \
        "$APP_NAME" "$DMG" >/dev/null
    echo "Made $DMG ($(du -sh "$DMG" | cut -f1)), $(lipo -archs "$APP/Contents/MacOS/CountYoTokens")"
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
