#!/bin/zsh
set -eu
cd "${0:A:h:h}"
ICONSET=$(mktemp -d "$PWD/assets/branding/.AppIcon-XXXXXX")
mv "$ICONSET" "$ICONSET.iconset"
ICONSET="$ICONSET.iconset"
trap 'rm -rf "$ICONSET"' EXIT
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/branding/kinky-notes-app-icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" assets/branding/kinky-notes-app-icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o assets/branding/AppIcon.icns
