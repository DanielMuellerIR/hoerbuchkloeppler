# Begrenzter Audiovergleich, kein Produktions-Encoding. macOS wegen aac_at und say.
import subprocess,pathlib,time,json,hashlib,array,math,statistics,os,tempfile,shutil
R=pathlib.Path(tempfile.mkdtemp(prefix='kloeppler-encoding-experiment-'));FF=os.environ.get('FFMPEG') or shutil.which('ffmpeg');results=[]
if not FF: raise SystemExit('ffmpeg fehlt; FFMPEG setzen')
print('Messordner:', R)
def run(args):
 start=time.monotonic();p=subprocess.run(args,capture_output=True);elapsed=time.monotonic()-start
 if p.returncode:raise RuntimeError(p.stderr.decode())
 return elapsed
run(['/usr/bin/say','-o',str(R/'speech.aiff'),'Heute lesen wir ein Hörbuch. Die Kapitel bleiben in ihrer Reihenfolge. Eine ruhige Stimme erzählt von einem Spaziergang durch den Wald. Zwischen den Bäumen hört man Wasser und Wind. Am Abend kehren wir nach Hause zurück.'] )
run([FF,'-v','error','-y','-stream_loop','-1','-i',str(R/'speech.aiff'),'-t','40','-ar','44100','-ac','1',str(R/'speech.wav')])
run([FF,'-v','error','-y','-f','lavfi','-i','aevalsrc=0.12*sin(2*PI*220*t)+0.07*sin(2*PI*277.18*t)+0.05*sin(2*PI*329.63*t):s=48000:d=40','-ac','2',str(R/'music.flac')])
run([FF,'-v','error','-y','-i',str(R/'speech.wav'),'-af','loudnorm=I=-16:TP=-1.5:LRA=11','-ar','48000','-c:a','aac_at','-aac_at_mode','cvbr','-b:a','96k',str(R/'normalized.m4a')])
segments=[('speech.wav',.123,13.719),('music.flac',.271,17.143),('normalized.m4a',.019,11.567),('speech.wav',14.133,12.499),('music.flac',18.271,18.721),('normalized.m4a',12.019,14.357)]
codec=['-c:a','aac_at','-aac_at_mode','cvbr','-b:a','96k','-ar','48000','-ac','2']
base=[FF,'-v','error','-nostdin','-y']
for trial in range(3):
 start=time.monotonic();wavs=[]
 for i,(name,ss,dur) in enumerate(segments):
  out=R/f'{i}.wav';wavs.append(out)
  run(base+['-ss',str(ss),'-t',str(dur),'-i',str(R/name),'-vn','-acodec','pcm_s16le','-ar','48000','-ac','2',str(out)])
 (R/'concat.txt').write_text(''.join(f"file '{p}'\n" for p in wavs))
 run(base+['-f','concat','-safe','0','-i',str(R/'concat.txt')]+codec+[str(R/f'standard-{trial}.m4b')])
 standard_seconds=time.monotonic()-start;temp_bytes=sum(p.stat().st_size for p in wavs)
 inputs=[];filters=[]
 for i,(name,ss,dur) in enumerate(segments):
  inputs+=['-ss',str(ss),'-t',str(dur),'-i',str(R/name)]
  filters.append(f'[{i}:a]aresample=48000,aformat=sample_fmts=s16:channel_layouts=stereo,asetpts=PTS-STARTPTS[a{i}]')
 filters.append(''.join(f'[a{i}]' for i in range(len(segments)))+f'concat=n={len(segments)}:v=0:a=1[out]')
 direct_args=base+inputs+['-filter_complex',';'.join(filters),'-map','[out]']+codec+[str(R/f'direct-{trial}.m4b')]
 direct_seconds=run(direct_args)
 (R/'direct-command.json').write_text(json.dumps(direct_args,indent=2))
 for mode in ['standard','direct']:
  run(base+['-i',str(R/f'{mode}-{trial}.m4b'),'-f','s16le','-c:a','pcm_s16le',str(R/f'{mode}-{trial}.pcm')])
 a=(R/f'standard-{trial}.pcm').read_bytes();b=(R/f'direct-{trial}.pcm').read_bytes();aa=array.array('h',a);bb=array.array('h',b)
 diff=[abs(x-y) for x,y in zip(aa,bb)];boundaries=[];offset=0
 for _,_,dur in segments[:-1]:
  offset+=dur;pos=round(offset*48000)*2;window=diff[max(0,pos-9600):pos+9600]
  boundaries.append(dict(expected_seconds=offset,max_abs_pcm_difference=max(window),rms_pcm_difference=math.sqrt(sum(x*x for x in window)/len(window))))
 results.append(dict(trial=trial,standard_seconds=standard_seconds,direct_seconds=direct_seconds,standard_temp_bytes=temp_bytes,direct_audio_temp_bytes=0,standard_decoded_seconds=len(a)/192000,direct_decoded_seconds=len(b)/192000,pcm_identical=a==b,max_abs_pcm_difference=max(diff),rms_pcm_difference=math.sqrt(sum(x*x for x in diff)/len(diff)),boundaries=boundaries))
(R/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
