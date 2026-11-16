#!/bin/bash
# Builds assets/googlesave/AppIcon.icns (the PokeTokenBar_gs app icon) from assets/googlesave/egg.png.
# Each size is rendered natively by generate-gs-icon.swift so the pixel art stays crisp.
set -euo pipefail
cd "$(dirname "$0")/.."

EGG="assets/googlesave/egg.png"
ICONSET="build/GSAppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"

gen() { swift scripts/generate-gs-icon.swift "$EGG" "$ICONSET/$1" "$2"; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png     128
gen icon_128x128@2x.png  256
gen icon_256x256.png     256
gen icon_256x256@2x.png  512
gen icon_512x512.png     512
gen icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET" -o assets/googlesave/AppIcon.icns
rm -rf "$ICONSET"
echo "done: assets/googlesave/AppIcon.icns"
