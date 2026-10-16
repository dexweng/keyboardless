#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="$PWD/.local/standalone/keyboardless.app"
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
PREVIEW="-local-preview"
if [ -n "${KEYBOARDLESS_NOTARY_PROFILE:-}" ]; then
  : "${KEYBOARDLESS_SIGN_IDENTITY:?Set a Developer ID Application identity}"
  case "$KEYBOARDLESS_SIGN_IDENTITY" in 'Developer ID Application:'*) ;; *) echo 'Developer ID Application identity required'; exit 1;; esac
  codesign --verify --deep --strict "$APP"
  codesign -dv --verbose=2 "$APP" 2>&1 | /usr/bin/grep 'Authority=Developer ID Application:' >/dev/null
  ditto -c -k --keepParent "$APP" .local/standalone/notarize.zip
  xcrun notarytool submit .local/standalone/notarize.zip --keychain-profile "$KEYBOARDLESS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  PREVIEW=""
fi
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/keyboardless.app"
ln -s /Applications "$STAGE/Applications"
printf '將 keyboardless 拖入 Applications，再開啟設定自己的 OpenAI API Key。\n首次使用需允許麥克風與輔助使用。\n' > "$STAGE/安裝說明.txt"
mkdir -p .local/releases
DMG="$PWD/.local/releases/keyboardless-${VERSION}-mac-universal${PREVIEW}.dmg"
hdiutil create -volname keyboardless -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if [ -n "${KEYBOARDLESS_NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "$KEYBOARDLESS_SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$KEYBOARDLESS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
shasum -a 256 "$DMG" | sed "s|$PWD/.local/releases/||" > "$DMG.sha256"
echo "$DMG"
