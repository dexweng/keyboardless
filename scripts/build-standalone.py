#!/usr/bin/env python3
"""Build a relocatable universal macOS app, never copying local user data."""
import hashlib, json, os, pathlib, plistlib, shutil, subprocess, tarfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
os.chdir(ROOT)
VERSION = json.loads((ROOT/'package.json').read_text())['version']
NODE_VERSION = '24.22.0'
HASHES = {'arm64':'6a9724d9b50a5f22b4816cded441b5a8d9ddae546191a5e5b7efa5a5e2ee26d5',
          'x64':'495e3f273c645f3c4677d438304cdfc701729ea5dec5728f5c8e76a2dece4b91'}
BUILD = ROOT/'.local/standalone'
APP = BUILD/'keyboardless.app'
CACHE = ROOT/'.local/runtime-downloads'
IDENTITY = os.environ.get('KEYBOARDLESS_SIGN_IDENTITY', '-')
def run(*args): subprocess.run([str(v) for v in args], check=True)
def copy(source, target):
    target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(source,target)
def sign(path, identifier=None, entitlements=None):
    args=['codesign','--force','--sign',IDENTITY,'--options','runtime']
    if IDENTITY != '-': args += ['--timestamp']
    if identifier: args += ['--identifier',identifier]
    if entitlements: args += ['--entitlements',entitlements]
    run(*args,path)
BUILD.mkdir(parents=True,exist_ok=True); CACHE.mkdir(parents=True,exist_ok=True)
if APP.exists(): shutil.rmtree(APP) # Only the dedicated generated staging bundle.
mac=APP/'Contents/MacOS'; res=APP/'Contents/Resources'
mac.mkdir(parents=True); res.mkdir(parents=True)
run('npm','run','build')
run('node_modules/.bin/esbuild','src/server.ts','--bundle','--platform=node','--format=esm','--packages=external','--outfile='+str(res/'service/server.mjs'))
for name in ['package.json','package-lock.json']: copy(ROOT/name,res/name)
run('npm','ci','--omit=dev','--ignore-scripts','--prefix',res)
for name in ['public','fixtures']:
    (res/name).mkdir()
    patterns=['*.html','*.css','client.js'] if name=='public' else ['cases.json']
    for pattern in patterns:
        for p in (ROOT/name).glob(pattern): copy(p,res/name/p.name)
for name in ['LICENSE','PRIVACY.md','THIRD_PARTY_NOTICES.md']: copy(ROOT/name,res/name)
for name in ['keyboardless-logo.png','keyboardless.icns','recording-start.wav']: copy(ROOT/'macos/Resources'/name,res/name)
node_bins=[]
for arch,digest in HASHES.items():
    archive=CACHE/('node-'+arch+'.tar.gz')
    if not archive.exists():
        urllib.request.urlretrieve('https://nodejs.org/download/release/v'+NODE_VERSION+'/node-v'+NODE_VERSION+'-darwin-'+arch+'.tar.gz',archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=digest: raise RuntimeError('Node archive checksum mismatch: '+arch)
    prefix='node-v'+NODE_VERSION+'-darwin-'+arch+'/'
    with tarfile.open(archive) as tar:
        binary=CACHE/('node-'+arch)
        binary.write_bytes(tar.extractfile(prefix+'bin/node').read()); binary.chmod(0o755)
        (res/'NODE-LICENSE.txt').write_bytes(tar.extractfile(prefix+'LICENSE').read())
    node_bins.append(binary)
run('lipo','-create',*node_bins,'-output',mac/'node')
module_cache=ROOT/'.local/swift-module-cache'; module_cache.mkdir(exist_ok=True)
for executable,sources,frameworks in [
    ('DexVoice',list((ROOT/'macos/Sources').glob('*.swift')),['AppKit','AVFoundation','Carbon','ApplicationServices']),
    ('Keychain',[ROOT/'macos/Keychain/main.swift'],['Security']),
    ('AudioPrepare',[ROOT/'macos/AudioPrepare/main.swift'],['AudioToolbox'])]:
    slices=[]
    for arch in ['arm64','x86_64']:
        binary=BUILD/(executable+'-'+arch)
        args=['xcrun','swiftc','-swift-version','5','-O','-target',arch+'-apple-macosx14.0','-module-cache-path',module_cache]
        for framework in frameworks: args += ['-framework',framework]
        run(*args,*sources,'-o',binary); slices.append(binary)
    run('lipo','-create',*slices,'-output',mac/executable)
info={'CFBundleExecutable':'DexVoice','CFBundleIdentifier':'local.dex.voice','CFBundleName':'keyboardless',
      'CFBundleDisplayName':'keyboardless','CFBundlePackageType':'APPL','CFBundleVersion':'3',
      'CFBundleShortVersionString':VERSION,'CFBundleIconFile':'keyboardless.icns','LSMinimumSystemVersion':'14.0',
      'LSUIElement':True,'NSMicrophoneUsageDescription':'使用快捷鍵錄下你的口述，交由你設定的 OpenAI 帳戶辨識。',
      'NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
(APP/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(res/'runtime.json').write_text(json.dumps({'mode':'standalone'})+'\n')
(res/'runtime-manifest.json').write_text(json.dumps({'nodeVersion':NODE_VERSION,'officialArchiveSHA256':HASHES,'version':VERSION},indent=2)+'\n')
for binary in mac.iterdir():
    deps=subprocess.check_output(['otool','-L',str(binary)]).decode().splitlines()[1:]
    if any('/opt/homebrew/' in line or '/usr/local/' in line for line in deps): raise RuntimeError('External runtime library: '+binary.name)
sign(mac/'node','local.dex.voice.node',ROOT/'macos/entitlements/node.plist')
sign(mac/'Keychain','local.dex.voice.keychain')
sign(mac/'AudioPrepare','local.dex.voice.audio')
sign(mac/'DexVoice','local.dex.voice',ROOT/'macos/entitlements/app.plist')
sign(APP,'local.dex.voice',ROOT/'macos/entitlements/app.plist')
run('codesign','--verify','--deep','--strict',APP)
print(json.dumps({'app':str(APP),'version':VERSION,'universal':True,'developerIDSigned':IDENTITY.startswith('Developer ID Application:')}))
