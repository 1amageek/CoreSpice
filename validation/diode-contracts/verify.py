#!/usr/bin/env python3
"""Build the exact production targets independently and execute their contracts."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--phase', choices=['native', 'portable', 'integration'], required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
fixture = out / 'component'
env = dict(os.environ)
records = []


def run(label, command, timeout=60):
    start = time.monotonic()
    result = subprocess.run(command, env=env, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    (out / f'{label}.log').write_text(result.stdout + result.stderr)
    records.append({'step': label, 'command': command, 'exit': result.returncode,
                    'seconds': time.monotonic() - start})
    (out / f'{args.phase}-commands.json').write_text(json.dumps(records, indent=2))
    if result.returncode:
        print((result.stdout + result.stderr)[-10000:])
        raise SystemExit(f'{label} failed: {result.returncode}')
    print(f'{label}: passed ({records[-1]["seconds"]:.2f}s)', flush=True)
    return result.stdout + result.stderr


sources = ['CoreSpiceEvaluationContracts', 'CoreSpiceDiodeContracts']
for name in sources:
    target = fixture / 'Sources' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        target.symlink_to(ROOT / 'Sources' / name, target_is_directory=True)
    test = fixture / 'Tests' / (name + 'Tests')
    test.parent.mkdir(parents=True, exist_ok=True)
    if not test.exists():
        test.symlink_to(ROOT / 'Tests' / (name + 'Tests'), target_is_directory=True)
probe = fixture / 'Sources' / 'DiodeContractsProbe'
probe.mkdir(exist_ok=True)
if not (probe / 'ContractsProbe.swift').exists():
    (probe / 'ContractsProbe.swift').symlink_to(ROOT / 'validation/diode-contracts/ContractsProbe.swift')
manifest = '''// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "DiodeD1", platforms: [.macOS(.v27)], targets: [
 .target(name: "CoreSpiceEvaluationContracts", exclude: ["DESIGN.md", "Environment/DESIGN.md"]),
 .target(name: "CoreSpiceDiodeContracts", dependencies: ["CoreSpiceEvaluationContracts"], exclude: ["DESIGN.md", "Input/DESIGN.md"]),
 .testTarget(name: "CoreSpiceEvaluationContractsTests", dependencies: ["CoreSpiceEvaluationContracts"]),
 .testTarget(name: "CoreSpiceDiodeContractsTests", dependencies: ["CoreSpiceEvaluationContracts", "CoreSpiceDiodeContracts"]),
 .executableTarget(name: "DiodeContractsProbe", dependencies: ["CoreSpiceEvaluationContracts", "CoreSpiceDiodeContracts"])
])
'''
(fixture / 'Package.swift').write_text(manifest)
swift = ['xcrun', 'swift']
version = run('toolchain-' + args.phase, swift + ['--version'], 15)
assert 'Swift version 6.4 (swift-6.4-RELEASE)' in version
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
          for target in sources for p in sorted((ROOT / 'Sources' / target).rglob('*.swift'))}
for directory in ['Tests/CoreSpiceEvaluationContractsTests', 'Tests/CoreSpiceDiodeContractsTests', 'validation/diode-contracts']:
    for p in sorted((ROOT / directory).rglob('*')):
        if p.is_file() and p.suffix in ['.swift', '.py']:
            hashes[str(p.relative_to(ROOT))] = hashlib.sha256(p.read_bytes()).hexdigest()
hashes['Package.swift'] = hashlib.sha256((ROOT / 'Package.swift').read_bytes()).hexdigest()
if args.phase == 'native':
    tests = run('native-tests', swift + ['test', '--package-path', str(fixture), '--build-path', str(out / 'native'), '--jobs', '4'])
    assert sorted(int(count) for count in re.findall(r'Test run with (\d+) tests in 1 suite passed', tests)) == [6, 12]
    run('native-probe', [str(out / 'native/debug/DiodeContractsProbe')], 10)
elif args.phase == 'portable':
    sdk = run('sdks', swift + ['sdk', 'list'], 15)
    runner = out / 'run-wasi.mjs'
    runner.write_text("import { WASI } from 'node:wasi'; import { readFile } from 'node:fs/promises';\n"
                      "const wasi = new WASI({version:'preview1', args:['DiodeContractsProbe'], env:{}, preopens:{}});\n"
                      "const module = await WebAssembly.compile(await readFile(process.argv[2]));\n"
                      "const instance = await WebAssembly.instantiate(module, wasi.getImportObject()); wasi.start(instance);\n")
    run('node-version', ['node', '--version'], 10)
    for mode in ['wasm', 'wasm-embedded']:
        sdk_id = 'swift-6.4.0-RELEASE_' + mode
        assert sdk_id in sdk.splitlines()
        build = out / mode
        command = swift + ['build', '--package-path', str(fixture), '--build-path', str(build),
                           '--swift-sdk', sdk_id, '--product', 'DiodeContractsProbe', '--jobs', '4']
        if mode == 'wasm-embedded':
            command += ['-Xswiftc', '-whole-module-optimization', '-Xswiftc', '-Onone',
                        '-Xlinker', '-lswiftUnicodeDataTables']
        run(mode + '-build', command, 120)
        binaries = list(build.glob('**/debug/DiodeContractsProbe.wasm'))
        assert binaries
        run(mode + '-runtime', ['node', str(runner), str(binaries[0])], 20)
else:
    package = json.loads(run('root-package', swift + ['package', 'dump-package'], 30))
    targets = {t['name']: t for t in package['targets']}
    assert targets[sources[0]]['dependencies'] == []
    assert targets[sources[1]]['dependencies'] == [{'byName': [sources[0], None]}]
    for phase in ['native', 'portable']:
        previous = json.loads((out / f'{phase}-evidence.json').read_text())
        assert previous['hashes'] == hashes, 'Sources changed after verification'
    for target in sources:
        run('registered-' + target, swift + ['build', '--target', target, '--build-path', str(ROOT / '.build'), '--jobs', '4'], 120)
    # Public constructors and distinct IDs must be enforced by the compiler.
    module_paths = list((out / 'native').glob('**/debug/Modules'))
    modules = module_paths[0] if module_paths else out / 'native/debug'
    for label, source in {
        'raw-si-geometry-mix': 'import CoreSpiceDiodeContracts\nfunc f(_ si: DiodePerimeterMetres) { _ = RawDiodeGeometry(area: nil, perimeter: si) }\n',
        'schema-forgery': 'import CoreSpiceDiodeContracts\nlet x = DiodeSchemaIdentity(law: .coreJunctionV1, revision: 99)\n',
        'model-instance-id-mix': 'import CoreSpiceDiodeContracts\nfunc f(_ x: DiodeModelInput) { _ = x.value(for: DiodeInstanceParameterID.parallelMultiplicity) }\n',
    }.items():
        path = out / (label + '.swift')
        path.write_text(source)
        result = subprocess.run(['xcrun', 'swiftc', '-typecheck', '-I', str(modules), str(path)],
                                env=env, capture_output=True, text=True, timeout=20)
        (out / (label + '.log')).write_text(result.stdout + result.stderr)
        assert result.returncode != 0 and 'error:' in result.stderr
        assert 'no such module' not in result.stderr
        if label == 'raw-si-geometry-mix':
            assert 'cannot convert value of type' in result.stderr
            assert 'DiodePerimeterMetres' in result.stderr and 'DiodeInputPerimeter' in result.stderr
        elif label == 'model-instance-id-mix':
            assert 'cannot convert value of type' in result.stderr
            assert 'DiodeInstanceParameterID' in result.stderr and 'DiodeModelParameterID' in result.stderr
        else:
            assert 'inaccessible' in result.stderr or 'extra argument' in result.stderr
        print(label + ': rejected by compiler', flush=True)
(out / f'{args.phase}-evidence.json').write_text(json.dumps({'phase': args.phase, 'hashes': hashes, 'commands': records}, indent=2))
