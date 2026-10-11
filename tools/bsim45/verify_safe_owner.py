"""Bounded Swift 6.4 safe-owner proof, using production component source links."""
from pathlib import Path
import argparse, json, os, signal, subprocess, time

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
package = Path(__file__).resolve().parents[2]
output = args.output.resolve()
fixture = output / 'component'
fixture.mkdir(parents=True, exist_ok=True)
for name in ['CoreSpiceMOSContracts', 'CoreSpiceBSIM45']:
    link = fixture / 'Sources' / name
    link.parent.mkdir(exist_ok=True)
    if not link.exists(): link.symlink_to(package / 'Sources' / name, target_is_directory=True)
compact = fixture / 'Sources/CoreSpiceCompactModels'
compact.mkdir(exist_ok=True)
for name in ['BSIM45', 'PreparationStorage']:
    link = compact / name
    if not link.exists(): link.symlink_to(package / 'Sources/CoreSpiceCompactModels' / name, target_is_directory=True)
probe = fixture / 'Sources/SyncProbe'
probe.mkdir(exist_ok=True)
(probe / 'Probe.swift').write_text((package / 'tools/bsim45/SyncProbe.swift').read_text())
(fixture / 'Tests').mkdir(exist_ok=True)
link = fixture / 'Tests/CoreSpiceBSIM45KernelTests'
if not link.exists(): link.symlink_to(package / 'Tests/CoreSpiceBSIM45KernelTests', target_is_directory=True)
(fixture / 'Package.swift').write_text('''// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "BSIM45OwnerProof", platforms: [.macOS(.v27)], targets: [
.target(name: "CoreSpiceMOSContracts", exclude: ["DESIGN.md", "Values/DESIGN.md", "Schema/DESIGN.md", "Preparation/DESIGN.md"]),
.target(name: "CoreSpiceBSIM45", exclude: ["DESIGN.md", "NOTICE.md", "Proof", "Kernel/DESIGN.md", "Kernel/B4TERMS_OF_USE", "Kernel/upstream.json", "Kernel/adapt_upstream.py", "Kernel/admission.inc", "Kernel/finite.inc"], publicHeadersPath: "include"),
.target(name: "CoreSpiceCompactModels", dependencies: ["CoreSpiceBSIM45", "CoreSpiceMOSContracts"], exclude: ["BSIM45/DESIGN.md", "PreparationStorage/DESIGN.md"]),
.executableTarget(name: "SyncProbe", dependencies: ["CoreSpiceCompactModels"]),
.testTarget(name: "CoreSpiceBSIM45KernelTests", dependencies: ["CoreSpiceCompactModels", "CoreSpiceMOSContracts"])
], cLanguageStandard: .c17)
''')
runner = output / 'run-wasi.mjs'
runner.write_text('''import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';
const wasi = new WASI({version:'preview1', args:['SyncProbe'], env:{}, preopens:{}});
const module = await WebAssembly.compile(await readFile(process.argv[2]));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
wasi.start(instance);
''')
report = {'scope': 'Exact BSIM45 component source: same synchronization and minimal runtime; numerical accuracy qualified only on Native CPU', 'commands': []}
environment = dict(os.environ, TOOLCHAINS='org.swift.640202609131a')
def run(name, command):
    start = time.monotonic()
    with (output / (name + '.log')).open('w') as log:
        process = subprocess.Popen(command, cwd=fixture, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try: code = process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait(); code = 124
    report['commands'].append(dict(name=name, command=command, exitCode=code, seconds=time.monotonic()-start))
    (output / 'verification.json').write_text(json.dumps(report, indent=2))
    print(name, code, flush=True)
    if code: raise SystemExit(code)
run('native-tests', ['xcrun', 'swift', 'test', '-j', '6', '--filter', 'BSIM45KernelTests'])
run('native-tsan', ['xcrun', 'swift', 'test', '-j', '6', '--sanitize=thread', '--filter', 'BSIM45KernelTests'])
for name, sdk in [('wasm', 'swift-6.4.0-RELEASE_wasm'), ('embedded', 'swift-6.4.0-RELEASE_wasm-embedded')]:
    build = output / (name + '-build')
    run(name + '-build', ['xcrun', 'swift', 'build', '--build-path', str(build), '--swift-sdk', sdk, '-j', '6', '--product', 'SyncProbe', '-Xlinker', '-z', '-Xlinker', 'stack-size=1048576'])
    run(name + '-runtime', ['node', str(runner), str(build / 'out/Products/Debug-webassembly-wasm32/SyncProbe.wasm')])
report['status'] = 'passed'
(output / 'verification.json').write_text(json.dumps(report, indent=2))
