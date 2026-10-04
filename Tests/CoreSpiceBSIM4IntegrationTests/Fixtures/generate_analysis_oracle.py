"""Selected independent exact-4.8.3 circuit analysis; never a runtime backend."""
from pathlib import Path
import hashlib,json,subprocess,sys,time
oracle=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True)
reference=json.loads(Path(sys.argv[3]).read_text());records=[];start=time.monotonic()
for item in reference['cases']:
 name=item['name'];p=item['polarity'];model=item['modelParameters'];instance=item['instanceParameters'];bias=item['bias']
 source=f'Native BSIM4 DC {name}\n.options bsim4stressiterations=8\n.temp {item["temperature"]-273.15:.17g}\n.model process {"nmos"if p==1 else "pmos"} level=54 version=4.8.3 '+' '.join(f'{k}={v:.17g}'for k,v in model.items())+'\n'+f'VD d 0 {bias[1]:.17g}\nVG g 0 {bias[2]:.17g} AC 1\nVS s 0 0\nVB b 0 {bias[4]:.17g}\nM1 d g s b process '+' '.join(f'{k}={v:.17g}'for k,v in instance.items())+'\n'
 deck=source.replace('.options bsim4stressiterations=8\n','.options gmin=1e-12 reltol=1e-7 abstol=1e-15\n')+f'.control\nset numdgt=17\nset wr_singlescale\nop\nwrdata {out/name}.dat i(vd) i(vg)\nquit\n.endc\n.end\n'
 path=out/(name+'.cir');path.write_text(deck);r=subprocess.run([str(oracle),'-b',str(path)],cwd=out,capture_output=True,text=True,timeout=10);(out/(name+'.log')).write_text(r.stdout+r.stderr);r.check_returncode()
 values=list(map(float,(out/(name+'.dat')).read_text().splitlines()[-1].split()));assert len(values)==3
 records.append({'name':name,'source':source+'.end\n','currents':values[1:],'deckSHA256':hashlib.sha256(deck.encode()).hexdigest(),'rawSHA256':hashlib.sha256((out/(name+'.dat')).read_bytes()).hexdigest()})
analyses=[]
for p in [1,-1]:
 for kind in ['qs','bodygate','nqs']:
  name=f'{p}_{kind}';extras='rbodymod=1 rgatemod=3'if kind!='qs'else''
  if kind=='nqs':extras+=' trnqsmod=1 acnqsmod=1'
  source=f'''Native BSIM4 terminal analysis {name}
.options bsim4stressiterations=8
.model process {'nmos'if p==1 else 'pmos'} level=54 version=4.8.3 vth0={p*.7} u0=.05 toxe=10n
+ rsh=20 cgdo=.2n cgso=.3n cgbo=.1n
VD d 0 {p}
VG g 0 sin({p*1.2} {p*.03} 100Meg) ac {p}
VS s 0 0
VB b 0 {-p*.1}
M1 d g s b process l=1u w=10u ad=2p as=3p pd=12u ps=14u {extras} m=2 mult_i=1.3 mult_q=.8
'''
  deck=source.replace('.options bsim4stressiterations=8\n','.options gmin=1e-12 reltol=1e-7 abstol=1e-15\n')+f'''.control
set numdgt=17
set wr_singlescale
ac dec 1 1000 100Gig
wrdata {out/name}-ac.dat i(vd) i(vg)
tran 2p 2n
linearize i(vd) i(vg)
wrdata {out/name}-tran.dat i(vd) i(vg)
quit
.endc
.end
'''
  path=out/(name+'-analysis.cir');path.write_text(deck);r=subprocess.run([str(oracle),'-b',str(path)],cwd=out,capture_output=True,text=True,timeout=20);(out/(name+'-analysis.log')).write_text(r.stdout+r.stderr);r.check_returncode()
  ac=[list(map(float,line.split()))for line in (out/(name+'-ac.dat')).read_text().splitlines()];tran=[list(map(float,line.split()))for line in (out/(name+'-tran.dat')).read_text().splitlines()]
  samples=[min(tran,key=lambda row:abs(row[0]-i*1e-10))for i in range(1,21)];assert all(len(row)==3 for row in samples)
  analyses.append({'name':name,'source':source+'.end\n','ac':ac,'transient':samples,'deckSHA256':hashlib.sha256(deck.encode()).hexdigest(),'acSHA256':hashlib.sha256((out/(name+'-ac.dat')).read_bytes()).hexdigest(),'tranSHA256':hashlib.sha256((out/(name+'-tran.dat')).read_bytes()).hexdigest()})
(out/'analysis-oracle.json').write_text(json.dumps({'release':'4.8.3','oracleSHA256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'nativeSourceArchiveSHA256':'3e3bb0ccb0699cb50d3844b6a2f6ee00f3ec6e1149e3ce4867cf47f5b27b56f7','referenceProvenance':'ngspice-46 4.8.3 with independently corrected body/NQS charge multiplicity; no parameter or coefficient fit; host constants pinned in kernel evidence','nativeAdaptation':json.loads((Path(__file__).resolve().parents[3]/'Sources/CoreSpiceBSIM4/Kernel/upstream.json').read_text()),'dc':records,'analyses':analyses},indent=2)+'\n');print('DC',len(records),'AC/trans cases',len(analyses),'seconds',time.monotonic()-start)
