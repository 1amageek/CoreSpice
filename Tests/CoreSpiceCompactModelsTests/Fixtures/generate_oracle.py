"""Pin independent ngspice values; the simulator is only an oracle, not a runtime dependency."""
from pathlib import Path
import hashlib, json, re, shutil, subprocess, tempfile
out=Path(__file__).resolve().parent
executable=Path(shutil.which('ngspice')).resolve()
version=subprocess.run([str(executable),'--version'],text=True,capture_output=True,check=True,timeout=10).stdout
cases=[]
with tempfile.TemporaryDirectory(prefix='corespice-bsim3-oracle-') as temp:
 for polarity in ['nmos','pmos']:
  sign=1 if polarity=='nmos' else -1
  for name,d,g,b,temperature,capmod in [('cutoff',.1,.1,-.2,27,3),('linear',.1,1.2,-.2,27,3),
    ('saturation',1,1.2,-.1,27,3),('reverse',-.5,1.2,-.2,27,3),('body-forward',.2,1,.05,27,3),
    ('hot',1,1.2,-.1,80,3),('cap0',1,1.2,-.1,27,0),('cap1',1,1.2,-.1,27,1),('cap2',1,1.2,-.1,27,2)]:
   stem=f'{polarity}-{name}';bias=[0,sign*d,sign*g,0,sign*b,0,0,0]
   deck=f'''Native BSIM3 independent fixture {stem}
vd d 0 {bias[1]:.17g}
vg g 0 {bias[2]:.17g}
vs s 0 0
vb b 0 {bias[4]:.17g}
m1 d g s b reference w=10u l=1u ad=2p as=3p pd=12u ps=14u
.model reference {polarity} level=49 version=3.3.0 vth0={sign*.7} u0=500 tox=10n capmod={capmod} cj=1m cjsw=100p cgdo=200p cgso=300p
.temp {temperature}
.options gmin=1e-12
.control
set numdgt=17
op
print @m1[id] @m1[gm] @m1[gds] @m1[gmbs] @m1[qg] @m1[qd] @m1[qb]
quit
.endc
.end
'''
   path=Path(temp)/f'{stem}.cir';path.write_text(deck)
   process=subprocess.run([str(executable),'-b',str(path)],cwd=temp,text=True,capture_output=True,check=True,timeout=10)
   output=process.stdout+process.stderr
   values={key:float(value) for key,value in re.findall(r'@m1\[(\w+)\]\s*=\s*([\d.eE+\-]+)',output)}
   assert len(values)==7 and 'Fatal' not in output
   (out/f'{stem}.cir').write_text(deck);(out/f'{stem}.log').write_text(output)
   cases.append({'name':stem,'polarity':polarity,'bias':bias,'temperature':temperature+273.15,'capmod':capmod,'expected':values})
(out/'oracle.json').write_text(json.dumps({'source':'ngspice independent BSIM3 level49/version3.3.0',
 'executableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest(),'version':version,'cases':cases},indent=2)+'\n')
