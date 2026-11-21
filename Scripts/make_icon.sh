#!/bin/zsh
# Renders Scripts/make_icon.swift at every size macOS uses and packs them into Assets/AppIcon.icns,
# plus Assets/AppIcon.png (1024) for the README.
set -euo pipefail
cd "${0:A:h}/.."

work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
set=$work/AppIcon.iconset
mkdir -p "$set" Assets

swift Scripts/make_icon.swift "$work/1024.png" 1024
for size in 16 32 128 256 512; do
    swift Scripts/make_icon.swift "$set/icon_${size}x${size}.png" $size
    swift Scripts/make_icon.swift "$set/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil -c icns "$set" -o Assets/AppIcon.icns
cp "$work/1024.png" Assets/AppIcon.png
echo "Wrote Assets/AppIcon.icns and Assets/AppIcon.png"
