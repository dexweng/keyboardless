#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"
APP="$PROJECT_ROOT/macos/build/keyboardless.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PROJECT_ROOT/.local/swift-module-cache"
xcrun swiftc -swift-version 5 -O -module-cache-path "$PROJECT_ROOT/.local/swift-module-cache" \
  -framework AppKit -framework AVFoundation -framework Carbon -framework ApplicationServices \
  macos/Sources/*.swift -o "$APP/Contents/MacOS/DexVoice"
xcrun swiftc -O -module-cache-path "$PROJECT_ROOT/.local/swift-module-cache" -framework Security macos/Keychain/main.swift -o "$APP/Contents/MacOS/Keychain"
codesign --force --sign - --identifier local.dex.voice.keychain "$APP/Contents/MacOS/Keychain"
export DEX_BUILD_APP="$APP" DEX_PROJECT_ROOT="$PROJECT_ROOT" DEX_NODE_PATH="$(command -v node)"
/usr/bin/python3 <<'PY'
import json, os, plistlib
app=os.environ['DEX_BUILD_APP']
with open(app+'/Contents/Info.plist','wb') as f:
    plistlib.dump({'CFBundleExecutable':'DexVoice','CFBundleIdentifier':'local.dex.voice','CFBundleName':'keyboardless','CFBundleDisplayName':'keyboardless','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':json.load(open('package.json'))['version'],'CFBundleIconFile':'keyboardless.icns','LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSMicrophoneUsageDescription':'使用快捷鍵開始錄下你的口述，交給已設定的語音服務辨識。','NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}},f)
with open(app+'/Contents/Resources/runtime.json','w') as f:
    json.dump({'projectRoot':os.environ['DEX_PROJECT_ROOT'],'nodePath':os.environ['DEX_NODE_PATH']},f)
PY
cp macos/Resources/keyboardless-logo.png macos/Resources/keyboardless.icns "$APP/Contents/Resources/"
cp macos/Resources/recording-start.wav "$APP/Contents/Resources/recording-start.wav"
codesign --force --sign - --identifier local.dex.voice "$APP"
codesign --verify --strict "$APP"
echo "$APP"
