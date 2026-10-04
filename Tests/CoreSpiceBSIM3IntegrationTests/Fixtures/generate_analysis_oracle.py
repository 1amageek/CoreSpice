"""Independent native-composition fixtures; ngspice is never a runtime backend."""
from pathlib import Path
import argparse, hashlib, json, math, shutil, subprocess, tempfile
out = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--reference-executable', required=True)
arguments = parser.parse_args()
executable = Path(arguments.reference_executable).resolve()
# Derived only from these fixture's explicitly fixed geometry and defaults.
length = 1e-6
length_cv = length  # lint=dlc=ll=lw=lwl=0 in both original default tables.
nlx = 1.74e-7
original_elm = 5.0
reference_elm = original_elm * math.sqrt(1 + nlx / length) / length_cv**2
version = subprocess.run([str(executable), '--version'], text=True, capture_output=True, check=True, timeout=10).stdout
cases = []
with tempfile.TemporaryDirectory(prefix='corespice-bsim3-analysis-oracle-') as temporary:
    work = Path(temporary)
    for sign in [1, -1]:
        for nqs in [False, True]:
            name = ('nmos' if sign == 1 else 'pmos') + ('-nqs' if nqs else '-qs')
            body = f'''Native BSIM3 production analysis oracle {name}
.model process {'nmos' if sign == 1 else 'pmos'} level=49 version=3.3.0 vth0={sign * .7} u0=500 tox=10n
+ capmod=3 cj=1m cjsw=0.1n cgdo=0.2n cgso=0.3n rsh=20 acnqsmod={int(nqs)} nlx={nlx} elm={original_elm}
VD d 0 {sign}
VG g 0 sin({sign * 1.2} {sign * .03} 100Meg) ac {sign}
VS s 0 0
VB b 0 {-sign * .1}
M1 d g s b process w=10u l=1u ad=2p as=3p pd=12u ps=14u nqsmod={int(nqs)}
'''
            reference_body = body.replace(f'elm={original_elm}', f'elm={reference_elm}')
            deck = reference_body + '''.options gmin=1e-12 reltol=1e-7 abstol=1e-15
.control
set numdgt=17
set wr_singlescale
set wr_vecnames
ac lin 1 100Meg 100Meg
wrdata ac.dat i(vd) i(vg)
tran 2p 2n
linearize i(vd) i(vg)
wrdata tran.dat i(vd) i(vg)
quit
.endc
.end
'''
            path = work / (name + '.cir'); path.write_text(deck)
            result = subprocess.run([str(executable), '-b', str(path)], cwd=work, text=True, capture_output=True, check=True, timeout=20)
            assert 'Fatal' not in result.stdout + result.stderr
            ac = [[float(value) for value in line.split()] for line in (work / 'ac.dat').read_text().splitlines()[1:]]
            transient = [[float(value) for value in line.split()] for line in (work / 'tran.dat').read_text().splitlines()[1:]]
            assert len(ac) == 1 and len(ac[0]) == 5
            samples = []
            for index in range(1, 21):
                time = index * 1e-10
                row = min(transient, key=lambda row: abs(row[0] - time))
                assert len(row) == 3 and abs(row[0] - time) < 1e-15
                samples.append(row)
            (out / (name + '.cir')).write_text(deck)
            (out / (name + '.log')).write_text(result.stdout + result.stderr)
            cases.append({'name': name, 'source': body + '.end\n', 'ac': ac[0], 'transient': samples})
(out / 'analysis-oracle.json').write_text(json.dumps({'source': 'ngspice independent full terminal AC/transient currents',
    'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(), 'version': version,
    'referenceAuthority': {
        'sourceArchiveSHA256': 'a0d1699af1940b06649276dcd6ff5a566c8c0cad01b2f7b5e99dedbb4d64c19b',
        'tag': 'ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6',
        'originalB3tempSHA256': 'f6a8379cd98fe78dbbad74f003a3df9695b7c832ba40fc727ac4856f242de459',
        'originalB3ldSHA256': '65c608a7760a902d59eb9764841a291176b9a3b4fb81dce923dc08462f28f65c',
        'referenceOnlyDerivativePatch': 'dVdseffCV_dVb: (1.0 - T5) -> (T4 - T5)',
        'elmInputTransformation': 'elm_original * sqrt(1 + nlx/leff) / leffCV**2',
        'effectiveLeff': length, 'effectiveLeffCV': length_cv, 'nlx': nlx,
        'originalElm': original_elm, 'referenceElm': reference_elm,
        'geometryCorrections': {'lint': 0, 'dlc': 0, 'll': 0, 'lw': 0, 'lwl': 0},
        'referenceMobilityMultiplier': 1,
        'uncorrectedEvidence': 'uncorrected-analysis-oracle.json'
    }, 'cases': cases}, indent=2) + '\n')
