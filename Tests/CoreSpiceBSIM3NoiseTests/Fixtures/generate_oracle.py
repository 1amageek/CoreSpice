"""Independent transferred noise PSDs; the reference is never a runtime backend."""
from pathlib import Path
import argparse, hashlib, json, math, subprocess, tempfile, time
out = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--reference-executable', required=True)
arguments = parser.parse_args()
exe = Path(arguments.reference_executable).resolve()
source_root = exe.parent.parent
constants = (source_root/'src/include/ngspice/const.h').read_text()
assert '#define CHARGE 1.602176634e-19' in constants
assert '#define CONSTboltz 1.380649e-23' in constants
cases = []
configs = [(sign, mode, 300.15, 20, 1, False) for sign in [1, -1] for mode in range(1, 7)]
configs += [(sign, 2, temp, rsh, m, nqs) for sign in [1, -1]
            for temp, rsh, m, nqs in [(350.15, 20, 1, False), (300.15, 0, 1, False),
                                     (300.15, 20, 3, False), (300.15, 20, 1, True)]]
start = time.monotonic()
with tempfile.TemporaryDirectory(prefix='corespice-bsim3-noise-') as temporary:
    work = Path(temporary)
    for sign, mode, temp, rsh, multiplicity, nqs in configs:
        name = f'{"n" if sign == 1 else "p"}-mode{mode}-T{temp}-rsh{rsh}-m{multiplicity}-nqs{int(nqs)}'
        # These exact drawn/effective lengths and zero geometry corrections are
        # fixed by the fixture card, not inferred from observed noise outputs.
        leff = leff_cv = 1e-6
        nlx = 1.74e-7
        reference_elm = 5 * math.sqrt(1 + nlx/leff) / leff_cv**2
        source = f'''Native BSIM3 independent noise {name}
.model process {'nmos' if sign == 1 else 'pmos'} level=49 version=3.3.0 vth0={sign*.7} u0=500 tox=10n
+ capmod=3 cj=1m cjsw=0.1n cgdo=0.2n cgso=0.3n noimod={mode} kf=1e-25 af=1 ef=1
+ rsh={rsh} lintnoi=50n nlx={nlx} elm=5 acnqsmod={int(nqs)}
VD supply 0 {sign*2}
RL supply d 1k
VG g 0 {sign*1.2} ac 1
VS s 0 0
VB b 0 {-sign*.1}
M1 d g s b process w=10u l=1u ad=2p as=3p pd=12u ps=14u m={multiplicity} nqsmod={int(nqs)}
.end
'''
        deck = source.replace('elm=5 ', f'elm={reference_elm} ').replace('.end\n',f'''.temp {temp-273.15}
.options gmin=1e-12 reltol=1e-9 abstol=1e-16
.control
set numdgt=17
set wr_singlescale
set wr_vecnames
noise v(d) VG dec 1 100 100Meg 1
setplot noise1
wrdata noise.dat onoise_spectrum inoise_spectrum onoise.m1.rd onoise.m1.rs onoise.m1.id onoise.m1.1overf
quit
.endc
.end
''')
        path = work/'input.cir'; path.write_text(deck)
        run = subprocess.run([str(exe), '-b', str(path)],cwd=work,capture_output=True,text=True,timeout=20,check=True)
        assert 'Error:' not in run.stderr and 'Fatal' not in run.stderr
        rows = [[float(v) for v in line.split()] for line in (work/'noise.dat').read_text().splitlines()[1:]]
        assert len(rows) == 7 and all(len(row)==7 for row in rows)
        # ngspice display vectors are amplitude densities, including per-source
        # vectors. Square them once to recover the V^2/Hz analysis contract.
        psd = [[row[0]] + [value**2 for value in row[1:]] for row in rows]
        cases.append({'name':name,'source':source,'temperature':temp,'samples':psd,
                      'referenceInput':deck,'referenceLog':run.stdout+run.stderr})
metadata = {'source':'independent ngspice-46 transferred source PSDs',
    'executableSHA256':hashlib.sha256(exe.read_bytes()).hexdigest(),
    'sourceArchiveSHA256':'a0d1699af1940b06649276dcd6ff5a566c8c0cad01b2f7b5e99dedbb4d64c19b',
    'tag':'ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6',
    'referenceSourceSHA256':{str(p.relative_to(source_root)):hashlib.sha256(p.read_bytes()).hexdigest()
         for p in [source_root/'src/include/ngspice/const.h',source_root/'src/spicelib/devices/bsim3/b3noi.c',
                   source_root/'src/spicelib/devices/bsim3/b3temp.c',source_root/'src/spicelib/devices/bsim3/b3ld.c']},
    'referenceOnlyChanges':['SI2019 host primitive constants; original constants and discrepancy retained',
        'CTM product/chain body derivative correction documented by production oracle',
        'NQS elm input = original 5 * sqrt(1 + nlx/leff) / leffCV**2; source-derived, not fitted'],
    'geometry':{'leff':1e-6,'leffCV':1e-6,'nlx':1.74e-7,'lint':0,'dlc':0,'ll':0,'lw':0,'lwl':0},
    'integrationAuthority':'CoreSpice trapezoid of sampled PSD over [first,last]; ngspice native integral is not compared',
    'elapsedSeconds':time.monotonic()-start,'cases':cases}
(out/'oracle.json').write_text(json.dumps(metadata,indent=2)+'\n')
print('cases',len(cases),'samples',sum(len(c['samples']) for c in cases),'seconds',metadata['elapsedSeconds'])
