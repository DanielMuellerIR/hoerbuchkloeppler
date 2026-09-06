# Vollständig dekodierte AAC-Übergänge; toleriert nur Encoder-Vorlauf und Frame-Padding.
import pathlib,tempfile,subprocess,json,math,array,hashlib,uuid,wave,struct
repo=pathlib.Path(__file__).resolve().parents[1];cli=repo/'HoerbuchkloepplerCore/.build/debug/kloeppler';ff=repo/'HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg';r=pathlib.Path(tempfile.mkdtemp(prefix='kloeppler-transitions-'));rate=32000
# Voraussetzungen vorab prüfen: ffmpeg liegt nicht im Repo (./build.sh --deps-only), die CLI kommt aus swift build, ffprobe aus dem PATH.
import shutil
assert ff.exists(),f'ffmpeg fehlt: {ff} — vorher ./build.sh --deps-only ausführen'
assert cli.exists(),f'kloeppler fehlt: {cli} — vorher swift build --package-path HoerbuchkloepplerCore ausführen'
assert shutil.which('ffprobe'),'ffprobe fehlt im PATH (z. B. brew install ffmpeg)'
sources=[];sections=[];lengths=[.6,.7,.8];freqs=[660,440,880]
for i,freq in enumerate(freqs):
 p=r/f'{i}.wav'
 with wave.open(str(p),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(rate);w.writeframes(b''.join(struct.pack('<h',int(4000*math.sin(2*math.pi*freq*n/rate))) for n in range(rate*2)))
 sid=str(uuid.uuid4());sources.append(dict(id=sid,location=dict(path=p.name,isRelative=True),readLocation=dict(path=p.name,isRelative=True),sha256=hashlib.sha256(p.read_bytes()).hexdigest()));sections.append(dict(id=str(uuid.uuid4()),sourceID=sid,start=.1,duration=lengths[i],title=f'Kapitel {i+1}'))
project=r/'book.hkproject';project.write_text(json.dumps(dict(formatVersion=1,sources=sources,sections=sections,metadata=dict(title='Übergänge',author='',genre='Hörbuch',narrator='',series='',volumeNumber='',language='deu'),settings={},coverSuppressed=True)))
report=[]
for mode in ['standard','parallel']:
 out=r/f'{mode}.m4b';p=subprocess.run([str(cli),'--project',str(project),'--mode',mode,'--format','json','--output',str(out)],capture_output=True,check=True);assert json.loads(p.stdout.splitlines()[-1])['success']
 pcm=array.array('h',subprocess.check_output([str(ff),'-v','error','-i',str(out),'-map','0:a:0','-f','s16le','-']))
 chapterdata=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_chapters','-of','json',str(out)]))['chapters'];starts=[]
 for freq in freqs:
  found=[]
  for st in range(0,len(pcm)-320,160):
   block=pcm[st:st+320];scores=[(sum(v*math.cos(2*math.pi*f*n/rate) for n,v in enumerate(block))**2+sum(v*math.sin(2*math.pi*f*n/rate) for n,v in enumerate(block))**2)/320**2 for f in freqs]
   if scores[freqs.index(freq)]>1e6 and scores[freqs.index(freq)]>max(x for i,x in enumerate(scores) if i!=freqs.index(freq))*3:found.append(st/rate)
  assert found;starts.append(min(found))
 expected=[0,lengths[0],sum(lengths[:2])];offsets=[x-y for x,y in zip(starts,expected)]
 for i,(actual,mark) in enumerate(zip(starts,chapterdata)):
  assert abs(float(mark['start_time'])-expected[i])<=.0011
  # AAC_AT priming 2112 Samples; maximal zwei Auffüllframes à1024 je separatem Encode.
  bound=2048/rate + (i*(2112+2048)/rate if mode=='parallel' else 0)
  assert abs(actual-expected[i])<=bound,(mode,i,actual,expected[i],bound)
 duration=len(pcm)/rate;bound=(2048+(len(lengths)-1)*(2112+2048))/rate if mode=='parallel' else 2048/rate
 assert abs(duration-sum(lengths))<=bound,(mode,duration,bound)
 report.append(dict(mode=mode,plannedSeconds=sum(lengths),decodedSeconds=duration,audioStarts=starts,plannedChapterStarts=expected,offsetSeconds=offsets))
(r/'report.json').write_text(json.dumps(report,indent=2));print(r);print(json.dumps(report,indent=2))
