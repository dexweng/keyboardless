#!/usr/bin/env python3
"""Export reviewed sources only. Never export the working repository or its history."""
import hashlib, json, pathlib, re, subprocess, sys, zipfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = ['README.md','LICENSE','PRIVACY.md','SECURITY.md','CONTRIBUTING.md','THIRD_PARTY_NOTICES.md',
         'package.json','package-lock.json','tsconfig.json','.gitignore','.env.example',
         'start.command','start-mac.command','設定模型金鑰.command',
         'docs/release.md','macos/Resources/recording-start.wav','macos/Resources/keyboardless-logo.png','macos/Resources/keyboardless.icns']
PATTERNS = ['src/*.ts','tests/*.ts','public/*.html','public/*.css','fixtures/cases.json',
            'macos/AudioPrepare/*.swift','macos/entitlements/*.plist','macos/Sources/*.swift','macos/Keychain/*.swift','macos/Tests/*.swift','macos/Tests/*.mjs',
            'macos/scripts/*.sh','scripts/*.py','.github/workflows/*.yml']
SECRET = re.compile(rb'(?:sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,})')
PERSONAL = re.compile(rb'/Users/[A-Za-z0-9._-]+/', re.I)
def private_keys():
    path=ROOT/'.env'
    if not path.exists(): return []
    return [v.strip().strip(b'\'"') for v in re.findall(rb'^\s*(?:export\s+)?OPENAI_API_KEY\s*=([^\r\n]+)',path.read_bytes(),re.M) if v.strip()]
def check(data, label, keys=(), personal=False):
    if SECRET.search(data) or any(k in data for k in keys):
        raise ValueError('Secret detected in '+label+' (value withheld)')
    if personal and PERSONAL.search(data): raise ValueError('Private path/name detected in '+label)
def sources(root=ROOT):
    selected=set(FILES)
    for pattern in PATTERNS:
        selected.update(p.relative_to(root).as_posix() for p in root.glob(pattern))
    result=[]
    for name in sorted(selected):
        p=root/name
        if p.is_symlink() or not p.is_file(): raise ValueError('Missing or symlink source: '+name)
        result.append((name,p.read_bytes(),p.stat().st_mode))
    return result

def audit_history():
    keys=private_keys(); count=0
    records=subprocess.check_output(['git','rev-list','--objects','--all'],cwd=ROOT).splitlines()
    for row in records:
        oid=row.split(b' ',1)[0]
        kind=subprocess.check_output(['git','cat-file','-t',oid],cwd=ROOT).strip()
        if kind not in [b'blob',b'commit',b'tag']: continue
        data=subprocess.check_output(['git','cat-file','-p',oid],cwd=ROOT)
        check(data,'git object '+oid.decode()[:12],keys);count+=1
    print(json.dumps({'historyObjectsScanned':count,'secretsDetected':False,'note':'Private history is never exported; pattern scans are not a proof of absence.'}))

def export():
    entries=sources(); keys=private_keys()
    for name,data,_ in entries: check(data,name,keys,personal=True)
    dest=ROOT/'.local/releases';dest.mkdir(parents=True,exist_ok=True)
    version=json.loads((ROOT/'package.json').read_text())['version']
    output=dest/('keyboardless-'+version+'-source.zip')
    manifest={name:hashlib.sha256(data).hexdigest() for name,data,_ in entries}
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as z:
        for name,data,mode in entries:
            info=zipfile.ZipInfo('keyboardless/'+name);info.external_attr=mode<<16
            z.writestr(info,data,compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('keyboardless/SOURCE-MANIFEST.json',json.dumps(manifest,indent=2)+'\n')
    with zipfile.ZipFile(output) as z:
        assert z.testzip() is None
        assert len(z.namelist())==len(entries)+1
        for name in z.namelist(): check(z.read(name),name,keys,personal=True)
    digest=hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.zip.sha256').write_text(digest+'  '+output.name+'\n')
    print(json.dumps({'archive':str(output),'files':len(entries),'sha256':digest,'containsGitHistory':False,'secretScan':'passed'}))
if __name__=='__main__':
    try:
        if '--history' in sys.argv: audit_history()
        else: export()
    except Exception as e:
        print(str(e),file=sys.stderr);sys.exit(1)
