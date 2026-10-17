#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .local/keyboardless.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" macos/Resources/keyboardless-logo.png --out ".local/keyboardless.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" macos/Resources/keyboardless-logo.png --out ".local/keyboardless.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .local/keyboardless.iconset -o macos/Resources/keyboardless.icns
