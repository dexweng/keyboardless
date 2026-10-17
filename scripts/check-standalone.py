#!/usr/bin/env python3
"""Exercise a relocated app backend with a minimal PATH, no real key or user data."""
import hashlib,json,os,pathlib,plistlib,shutil,subprocess,tempfile,time,urllib.request,urllib.error,wave,math,struct,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
APP=pathlib.Path(sys.argv[1]).resolve() if len(sys.argv)>1 else ROOT/'.local/standalone/keyboardless.app'
PORT=3038
with tempfile.TemporaryDirectory(prefix='keyboardless-portable-') as name:
    work=pathlib.Path(name); app=work/'Relocated Folder/keyboardless.app'
    shutil.copytree(APP,app,symlinks=True)
    resources=app/'Contents/Resources'; binaries=app/'Contents/MacOS'
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIconFile']=='keyboardless.icns'
    assert json.loads((resources/'runtime.json').read_text())=={'mode':'standalone'}
    for binary in ['DexVoice','node','Keychain','AudioPrepare']:
        arch=subprocess.check_output(['lipo','-archs',str(binaries/binary)]).decode()
        assert 'arm64' in arch and 'x86_64' in arch
    assert not any(p.name in {'.env','.git','.local'} for p in app.rglob('*'))
    assert not (resources/'runtime.json').read_text().find('/Users/')>=0
    # All generated JS is source-path independent.
    for p in [resources/'service/server.mjs',resources/'public/client.js']:
        assert b'/Users/' not in p.read_bytes()
    original=work/'tone.wav'
    with wave.open(str(original),'wb') as f:
        f.setnchannels(2); f.setsampwidth(2); f.setframerate(44100)
        samples=b''.join(struct.pack('<hh',int(4000*math.sin(i*2*math.pi*440/44100)),int(4000*math.sin(i*2*math.pi*440/44100))) for i in range(44100))
        f.writeframes(samples)
    for source in [original]:
        output=work/'normalized.wav'
        result=json.loads(subprocess.check_output([str(binaries/'AudioPrepare'),str(source),str(output)]))
        assert abs(result['duration']-1)<0.01
        with wave.open(str(output),'rb') as f: assert (f.getframerate(),f.getnchannels(),f.getsampwidth())==(16000,1,2)
    m4a=work/'tone.m4a'
    subprocess.run(['/usr/bin/afconvert','-f','m4af','-d','aac',str(original),str(m4a)],check=True)
    result=json.loads(subprocess.check_output([str(binaries/'AudioPrepare'),str(m4a),str(work/'m4a.wav')]))
    assert 0.9<result['duration']<1.2
    mp3=work/'tone.mp3'
    subprocess.run([shutil.which('ffmpeg'),'-v','error','-i',str(original),str(mp3)],check=True)
    result=json.loads(subprocess.check_output([str(binaries/'AudioPrepare'),str(mp3),str(work/'mp3.wav')]))
    assert 0.9<result['duration']<1.2
    invalid=work/'invalid.wav' ;invalid.write_text('not audio')
    assert subprocess.run([str(binaries/'AudioPrepare'),str(invalid),str(work/'bad.wav')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
    assert not (work/'bad.wav').exists()
    # No Keychain access: test uses a missing helper and isolated data directory.
    env={'HOME':str(work),'PATH':'/usr/bin:/bin','TMPDIR':str(work),
         'KEYBOARDLESS_DATA_ROOT':str(work/'data'),'KEYBOARDLESS_ENV_FILE':str(work/'no.env'),
         'KEYBOARDLESS_KEYCHAIN_HELPER':str(work/'missing-helper'),
         'KEYBOARDLESS_AUDIO_HELPER':str(binaries/'AudioPrepare'),
         'KEYBOARDLESS_INSTANCE':'isolated-test','KEYBOARDLESS_PARENT_PID':str(os.getpid())}
    log=open(work/'service.log','wb')
    child=subprocess.Popen([str(binaries/'node'),str(resources/'service/server.mjs'),'--port',str(PORT)],cwd='/',env=env,stdout=log,stderr=log)
    try:
        config=None
        for _ in range(80):
            try:
                config=json.load(urllib.request.urlopen('http://127.0.0.1:'+str(PORT)+'/api/config',timeout=1)); break
            except (OSError,ValueError):
                if child.poll() is not None: raise RuntimeError('Bundled service exited '+str(child.returncode)+'; '+(work/'service.log').read_text())
                time.sleep(0.1)
        assert config and config['instanceID']=='isolated-test' and config['nativeAudio'] and not config['configured']
        assert (work/'data/runs').is_dir() and not (resources/'.local').exists()
        request=urllib.request.Request('http://127.0.0.1:'+str(PORT)+'/api/preferences',data=b'{}',headers={'Content-Type':'application/json'},method='PUT')
        try: urllib.request.urlopen(request); raise AssertionError('Unauthorized mutation accepted')
        except urllib.error.HTTPError as error: assert error.code==403
        conflict=subprocess.run([str(binaries/'node'),str(resources/'service/server.mjs'),'--port',str(PORT)],env={**env,'KEYBOARDLESS_DATA_ROOT':str(work/'conflict')},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
        assert conflict.returncode!=0
        orphan=subprocess.Popen([str(binaries/'node'),str(resources/'service/server.mjs'),'--port','3039'],
            env={**env,'KEYBOARDLESS_DATA_ROOT':str(work/'orphan'),'KEYBOARDLESS_PARENT_PID':'999999'},
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try: assert orphan.wait(timeout=5)==0
        finally:
            if orphan.poll() is None: orphan.terminate(); orphan.wait(timeout=5)
    finally:
        child.terminate();child.wait(timeout=10);log.close()
print('PASS: universal binaries, clean relocated app, minimal PATH service, isolated data, WAV/MP3/M4A conversion, invalid audio rejection, mutation protection and port conflict')
