# CLI-Abnahme: echte Split-Ausgaben, Rückimport, Fehler und Signalabbruch.
import pathlib,tempfile,subprocess,json,time,os,signal,selectors
REPO=pathlib.Path(__file__).resolve().parents[1]
CLI=REPO/'HoerbuchkloepplerCore/.build/debug/kloeppler'
FF=REPO/'HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg'
# Voraussetzungen vorab prüfen: ffmpeg liegt nicht im Repo (./build.sh --deps-only), die CLI kommt aus swift build.
assert FF.exists(),f'ffmpeg fehlt: {FF} — vorher ./build.sh --deps-only ausführen'
assert CLI.exists(),f'kloeppler fehlt: {CLI} — vorher swift build --package-path HoerbuchkloepplerCore ausführen'
ROOT=pathlib.Path(tempfile.mkdtemp(prefix='hk-final-matrix-'))
REPORT=[]
def tool(*args):
    return subprocess.run([str(FF),'-v','error',*map(str,args)],capture_output=True,check=True)
def run(args, expected=0):
    start=time.monotonic();p=subprocess.run([str(CLI),*map(str,args)],capture_output=True,timeout=300)
    (ROOT/f'command-{len(REPORT)}.stderr').write_bytes(p.stderr)
    assert p.returncode==expected,(args,p.returncode,p.stderr.decode()[-3000:])
    REPORT.append(dict(args=list(map(str,args)),seconds=round(time.monotonic()-start,3),exit=p.returncode))
    return p
def decoded(path):
    p=subprocess.Popen([str(FF),'-v','error','-i',str(path),'-map','0:a:0','-ac','1','-ar','8000','-f','s16le','-'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    count=0
    while True:
        data=p.stdout.read(1024*1024)
        if not data:break
        count+=len(data)
    assert p.wait()==0,p.stderr.read().decode()
    return count/2/8000

def inspect(path):return json.loads(run(['--file',path,'--inspect','--format','json']).stdout)
print('ROOT',ROOT,flush=True)
for index in [1,2]:
    tool('-f','lavfi','-i','anullsrc=r=8000:cl=mono','-t','1801','-c:a','flac','-metadata',f'title=Kapitel {index}',ROOT/f'{index}.flac')
tool('-f','lavfi','-i','color=c=blue:s=64x64','-frames:v','1','-threads','1',ROOT/'cover.png')
files=['--file',ROOT/'2.flac','--file',ROOT/'1.flac']
p=run([*files,'--inspect','--format','json','--output',ROOT/'absent'/'book.m4b','--no-cover'])
r=json.loads(p.stdout);assert [c['title'] for c in r['chapters']]==['Kapitel 2','Kapitel 1'];assert not (ROOT/'absent').exists();print('inspect order OK',flush=True)
metadata=['--title','Matrixbuch','--author','Autor','--narrator','Sprecher','--series','Reihe','--volume-number','2','--language','deu','--cover',ROOT/'cover.png']
for mode in ['standard','parallel']:
    p=run([*files,*metadata,'--mode',mode,'--max-duration','1','--samplerate','8000','--bitrate','24k','--workers','2','--format','json','--output',ROOT/f'{mode}.m4b'])
    events=[json.loads(line) for line in p.stdout.splitlines()]
    assert events[-1]['event']=='finished' and events[-1]['success'],events[-1]
    outputs=list(map(pathlib.Path,events[-1]['outputs']));assert len(outputs)==2,outputs
    for index,path in enumerate(outputs):
        r=inspect(path)
        assert r['hasCover'],r
        assert r['metadata']['narrator']=='Sprecher',r['metadata']
        assert r['metadata']['series']=='Reihe',r['metadata']
        assert r['metadata']['volumeNumber']=='2',r['metadata']
        assert r['metadata']['language']=='deu',r['metadata']
        assert len(r['chapters'])==1,r['chapters']
        assert r['chapters'][0]['title']==f'Kapitel {2-index}',r['chapters']
        seconds=decoded(path)
        # Einzelsegment: höchstens zwei AAC-Rahmen Randabweichung bei 8 kHz.
        assert abs(seconds-1801) <= 2*1024/8000,(path,seconds)
        REPORT.append(dict(mode=mode,output=path.name,decodedSeconds=seconds,chapter=r['chapters'][0],metadata=r['metadata'],cover=r['hasCover']))
        print(mode,path.name,'decodedSeconds',seconds,'metadata+cover reimport OK',flush=True)

def leftovers():
    temp=pathlib.Path(tempfile.gettempdir())
    return set(map(str,temp.glob('HB_Temp_*')))|set(map(str,temp.glob('HB_Loudness_*')))
def abort(sig,analyze=False):
    before=leftovers();target=ROOT/('cancel-analysis.m4b' if analyze else 'cancel-encoding.m4b')
    args=[str(CLI),*map(str,files),'--no-cover','--mode','standard','--samplerate','48000','--format','json','--output',str(target)]
    if analyze:args+=['--analyze-loudness']
    p=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    selector=selectors.DefaultSelector();selector.register(p.stderr,selectors.EVENT_READ,'err');selector.register(p.stdout,selectors.EVENT_READ,'out')
    buffers={'err':b'','out':b''};sent=None;deadline=time.monotonic()+60
    while p.poll() is None and time.monotonic()<deadline:
        for key,_ in selector.select(.1):
            chunk=os.read(key.fileobj.fileno(),65536)
            if not chunk:selector.unregister(key.fileobj);continue
            buffers[key.data]+=chunk
        marker=b'Lautheitsanalyse:' if analyze else b'"event":"started"'
        combined=buffers['err'] if analyze else buffers['out']
        if sent is None and marker in combined:
            if not analyze:time.sleep(.15)
            p.send_signal(sig);sent=time.monotonic()
    if p.poll() is None:p.kill();raise AssertionError('Cancellation timeout')
    out,err=p.communicate();buffers['out']+=out;buffers['err']+=err
    assert sent is not None,'Signal marker missing'
    assert p.returncode==128+sig,(p.returncode,buffers['err'].decode()[-3000:])
    events=[json.loads(line) for line in buffers['out'].splitlines()]
    assert events[-1]['event']=='cancelled',events
    assert not target.exists();assert not (leftovers()-before),leftovers()-before
    assert not list(ROOT.rglob('*.partial*'))
    REPORT.append(dict(signal=sig,analysis=analyze,exit=p.returncode,cancelSeconds=round(time.monotonic()-sent,3),cleanup=True))
    print('cancel',sig,'analysis',analyze,REPORT[-1],flush=True)
abort(signal.SIGINT)
abort(signal.SIGTERM,True)
(ROOT/'bad.wav').write_bytes(b'not audio')
p=run(['--file',ROOT/'bad.wav','--format','json','--output',ROOT/'bad.m4b'],1)
events=[json.loads(l) for l in p.stdout.splitlines()];assert events[-1]['event']=='failed';assert not (ROOT/'bad.m4b').exists()
(ROOT/'report.json').write_text(json.dumps(REPORT,indent=2,ensure_ascii=False))
print('VERIFIED',ROOT/'report.json',flush=True)
