#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="$PWD/macos/build/keyboardless.app"
codesign --verify --strict "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/file "$APP/Contents/MacOS/DexVoice"

/usr/bin/python3 - "$APP" <<'PYTHON'
import pathlib, plistlib, sys, wave
app=pathlib.Path(sys.argv[1])
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleDisplayName']=='keyboardless'
assert info['CFBundleIdentifier']=='local.dex.voice'
with wave.open(str(app/'Contents/Resources/recording-start.wav')) as cue:
    assert cue.getnchannels()==1 and cue.getsampwidth()==2
    assert 0.3 <= cue.getnframes()/cue.getframerate() <= 0.35
    assert any(cue.readframes(cue.getnframes()))
print('PASS: keyboardless identity and packaged recording cue (320 ms PCM)')
PYTHON
