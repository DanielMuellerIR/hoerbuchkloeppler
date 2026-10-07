#!/usr/bin/env python3
"""Reale CLI-Regressionsprüfung: Projekt, Reihenfolge, JSON und schreibfreies Inspect.

Vorher: swift build --package-path HoerbuchkloepplerCore
Fixtures bleiben zur Diagnose im ausgegebenen temporären Ordner.
"""
import pathlib, tempfile, wave, struct, math, json, uuid, hashlib, subprocess
root=pathlib.Path(tempfile.mkdtemp(prefix='hk-project-cli-'))
repo=pathlib.Path(__file__).resolve().parent
cli=repo/'HoerbuchkloepplerCore/.build/debug/kloeppler'
ffmpeg=repo/'HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg'
assert ffmpeg.exists(),f'ffmpeg fehlt: {ffmpeg} — vorher ./build.sh --deps-only ausführen'
assert cli.exists(),f'kloeppler fehlt: {cli} — vorher swift build --package-path HoerbuchkloepplerCore ausführen'
for name,freq in [('A',440),('B',660)]:
    with wave.open(str(root/f'{name}.wav'),'wb') as w:
        w.setnchannels(1);w.setsampwidth(2);w.setframerate(32000)
        w.writeframes(b''.join(struct.pack('<h',int(4000*math.sin(2*math.pi*freq*i/32000))) for i in range(32000)))
def run(args,code=0):
    p=subprocess.run([str(cli),*map(str,args)],capture_output=True,timeout=30)
    assert p.returncode==code,(args,p.returncode,p.stderr.decode()[-2000:])
    return p
p=run(['--file',root/'B.wav','--file',root/'A.wav','--inspect','--format','json','--no-cover','--output',root/'new'/'out.m4b'])
r=json.loads(p.stdout);assert r['schemaVersion']==1;assert [pathlib.Path(c['source']).name for c in r['chapters']]==['B.wav','A.wav'];assert not (root/'new').exists()
sources=[];sections=[]
for name,start,duration in [('B',0.2,0.6),('A',0.1,0.7)]:
    sid=str(uuid.uuid4());sources.append(dict(id=sid,location=dict(path=f'{name}.wav',isRelative=True),readLocation=dict(path=f'{name}.wav',isRelative=True),sha256=hashlib.sha256((root/f'{name}.wav').read_bytes()).hexdigest()))
    sections.append(dict(id=str(uuid.uuid4()),sourceID=sid,start=start,duration=duration,title=f'Bearbeitet {name}'))
project=dict(formatVersion=1,sources=sources,sections=sections,metadata=dict(title='Projektbuch',author='Autor',genre='Hörbuch',narrator='Sprecher',series='Reihe',volumeNumber='2',language='de'),settings={},coverSuppressed=True)
path=root/'test.hkproject';path.write_text(json.dumps(project))
r=json.loads(run(['--project',path,'--inspect','--format','json','--output',root/'another'/'out.m4b']).stdout)
assert abs(r['duration']-1.3)<1e-9,r['duration']
assert r['metadata']['narrator']=='Sprecher';assert not (root/'another').exists()
# Explizit geleerte GUI-Metadaten dürfen beim CLI-Reimport nicht zurückkehren.
empty_overrides=[value for option in ['--title','--author','--genre','--narrator','--series',
                                     '--volume-number','--language'] for value in [option,'']]
cleared=json.loads(run(['--project',path,'--inspect','--format','json',*empty_overrides]).stdout)
assert all(cleared['metadata'][key]=='' for key in
           ['title','author','genre','narrator','series','volumeNumber','language']),cleared['metadata']
print('explicit empty metadata overrides preserved')
# Nur der Standard-Modus: Den Parallel-Modus deckt tests/verify_cli_matrix.py ab.
for mode in ['standard']:
    output=root/f'{mode}.m4b'
    p=run(['--project',path,'--mode',mode,'--format','json','--output',output])
    events=[json.loads(l) for l in p.stdout.splitlines()]
    assert events[-1]['event']=='finished' and events[-1]['success']
    assert all(e['schemaVersion']==2 for e in events)
    assert all('success' in e for e in events)
    assert all(e['success'] is None for e in events if e['event'] in ('started','progress'))
    assert all(e['phase'] in ('input','preparing','measuring_loudness','decoding','encoding','muxing') for e in events)
    d=subprocess.run([str(ffmpeg),'-v','error','-i',str(output),'-map','0:a:0','-f','f32le','-ac','1','-ar','32000','-'],capture_output=True,check=True)
    duration=len(d.stdout)/4/32000
    assert abs(duration-1.3)<0.1,(mode,duration)
    meta=subprocess.run([str(ffmpeg),'-v','error','-i',str(output),'-f','ffmetadata','-'],capture_output=True,check=True).stdout.decode()
    assert 'Bearbeitet B' in meta and 'Bearbeitet A' in meta,meta
    print(mode,'decodedSeconds',duration,'jsonEvents',len(events))
(root/'B.wav').write_bytes(b'changed')
p=run(['--project',path,'--inspect','--format','json'],1)
assert len(json.loads(p.stdout)['sourceIssues'])==1
p=run(['--project',path,'--format','json','--output',root/'invalid.m4b'],1)
events=[json.loads(l) for l in p.stdout.splitlines()];assert events[-1]['event']=='failed'
assert events[-1]['phase']=='input' and events[-1]['success'] is False,events[-1]
assert not (root/'invalid.m4b').exists()
print('verified',root)
