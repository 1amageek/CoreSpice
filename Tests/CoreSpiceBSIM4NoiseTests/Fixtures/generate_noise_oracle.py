"""Independent selected BSIM4 noise; uses a prebuilt isolated oracle only."""
from pathlib import Path
import hashlib,json,subprocess,sys,time
oracle=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True)
channels=['rd','rs','rg','rbps','rbpd','rbpb','rbsb','rbdb','id','1overf','igs','igd','igb','corl']
variants=[]
for polarity in [1,-1]:
 for thermal in range(3):
  for flicker in range(2): variants.append((f'{polarity}-t{thermal}-f{flicker}',polarity,thermal,flicker,300.15,'rsh=20','nrd=1 nrs=1'))
extras=[('gate1', 'rsh=20 rshg=5 igcmod=2 igbmod=1', 'nrd=1 nrs=1 rgatemod=1'),
 ('gate2','rsh=20 rshg=5','nrd=1 nrs=1 rgatemod=2'),
 ('bodygate','rsh=20 rshg=5','nrd=1 nrs=1 rgatemod=3 rbodymod=1'),
 ('body2','rsh=20 rbps0=50 rbpd0=60 rbsbx0=40 rbdbx0=45','nrd=1 nrs=1 rbodymod=2'),
 ('nqs-scaled','rsh=20 rshg=5','nrd=1 nrs=1 rbodymod=1 rgatemod=3 trnqsmod=1 acnqsmod=1 m=2 mult_i=1.3 mult_q=.8 mult_fn=1.7'),
 ('rds','rdsmod=1 rsh=20','nrd=1 nrs=1'),
 ('reverse','rsh=20','nrd=1 nrs=1'),
 ('hot','rsh=20','nrd=1 nrs=1')]
for polarity in [1,-1]:
 for name,model,instance in extras:variants.append((f'{polarity}-{name}',polarity,2,1,350.15 if name=='hot'else 300.15,model,instance))
records=[];start=time.monotonic()
for name,p,t,f,temp,model,instance in variants:
 drain=-p if 'reverse' in name else p
 source=f"""Native BSIM4 independent noise {name}
.options bsim4stressiterations=8
.temp {temp-273.15:.17g}
.model process {'nmos' if p==1 else 'pmos'} level=54 version=4.8.3 vth0={p*.7} u0=.05 toxe={"2n" if "gate1" in name else "10n"}
+ tnoimod={t} fnoimod={f} kf=1e-25 capmod=2 {model}
VD supply 0 {drain*2}
RL supply d 1k
VG g 0 {p*1.2} ac 1
VS s 0 0
VB b 0 {-p*.1}
M1 d g s b process l=1u w=10u ad=2p as=3p pd=12u ps=14u {instance}
.noise V(d) VG dec 1 100 10Gig
"""
 deck=source.replace('.options bsim4stressiterations=8',' .options gmin=1e-12 reltol=1e-7 abstol=1e-15')+f""".control
set numdgt=17
set wr_singlescale
set sqrnoise
noise V(d) VG dec 1 100 10Gig 1
setplot noise1
wrdata {out/name}.dat onoise_spectrum inoise_spectrum {' '.join('onoise.m1.'+channel for channel in channels)}
quit
.endc
.end
"""
 path=out/(name+'.cir');path.write_text(deck)
 r=subprocess.run([str(oracle),'-b',str(path)],cwd=out,capture_output=True,text=True,timeout=10)
 (out/(name+'.log')).write_text(r.stdout+r.stderr);r.check_returncode()
 raw=out/(name+'.dat');samples=[list(map(float,line.split()))for line in raw.read_text().splitlines()]
 assert all(len(row)==17 for row in samples),(name,samples[:1])
 records.append({'name':name,'source':source+'.end\n','temperature':temp,'samples':samples,'deckSHA256':hashlib.sha256(deck.encode()).hexdigest(),'rawSHA256':hashlib.sha256(raw.read_bytes()).hexdigest()})
manifest=Path(__file__).resolve().parents[3]/'Sources/CoreSpiceBSIM4/Kernel/upstream.json'
reference={'oracleSHA256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'reference':'ngspice-46 4.8.3 with independently corrected body/NQS charge multiplicity, SI2019 host constants; not pristine original for affected scaling','nativeAdaptation':json.loads(manifest.read_text()),'integrationAuthority':'Public CoreSpice trapezoidal sampled output PSD, not ngspice native Nintegrate','channels':channels,'cases':records,'elapsedSeconds':time.monotonic()-start}
if len(sys.argv)>3:
 alignment=Path(sys.argv[3])
 reference['constantAlignmentProvenance']={'before':json.loads((alignment/'provenance-before.json').read_text()),'selectedRebuild':json.loads((alignment/'selected-rebuild.json').read_text())}
(out/'oracle.json').write_text(json.dumps(reference,indent=2)+'\n');print('cases',len(records),'seconds',time.monotonic()-start)
