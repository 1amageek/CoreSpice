#!/usr/bin/env python3
"""Exercise exact production evaluation sources without numerical dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
fixture = out / 'portable-component'
env = dict(os.environ, TOOLCHAINS='org.swift.640202609131a')
records = []
targets = ['CoreSpiceEvaluationContracts', 'CoreSpiceMOSContracts', 'CoreSpiceMOSResolution']
for name in targets:
    link = fixture / 'Sources' / name
    link.parent.mkdir(parents=True, exist_ok=True)
    if not link.exists():
        link.symlink_to(ROOT / 'Sources' / name, target_is_directory=True)
probe = fixture / 'Sources' / 'EnvironmentProbe'
probe.mkdir(exist_ok=True)
(probe / 'EnvironmentProbe.swift').write_text((ROOT / 'validation/temperature-environment/EnvironmentProbe.swift').read_text())
entries = []
for name in targets:
    dependencies = [] if name == targets[0] else [targets[0]] if name == targets[1] else targets[:2]
    excludes = [str(p.relative_to(ROOT / 'Sources' / name)) for p in sorted((ROOT / 'Sources' / name).rglob('*'))
                if p.is_file() and p.suffix != '.swift']
    entries.append(f'.target(name: "{name}", dependencies: {json.dumps(dependencies)}, exclude: {json.dumps(excludes)})')
entries.append('.executableTarget(name: "EnvironmentProbe", dependencies: ' + json.dumps(targets) + ')')
(fixture / 'Package.swift').write_text('// swift-tools-version: 6.4\nimport PackageDescription\nlet package = Package(name: "TemperatureD2", platforms: [.macOS(.v27)], targets: [' + ',\n'.join(entries) + '])\n')


def run(label, command, timeout=120):
    start = time.monotonic()
    try:
        result = subprocess.run(command, env=env, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        (out / (label + '.log')).write_bytes((error.stdout or b'') + (error.stderr or b''))
        raise
    (out / (label + '.log')).write_text(result.stdout + result.stderr)
    records.append(dict(step=label, command=command, exit=result.returncode, seconds=time.monotonic()-start))
    (out / 'portable-commands.json').write_text(json.dumps(records, indent=2))
    if result.returncode:
        print((result.stdout + result.stderr)[-6000:])
        raise SystemExit(label + ' failed')
    print(label + ': passed', flush=True)
    return result.stdout

assert 'Swift version 6.4 (swift-6.4-RELEASE)' in run('toolchain', ['xcrun', 'swift', '--version'], 15)
sdks = run('sdks', ['xcrun', 'swift', 'sdk', 'list'], 15)
run('node-version', ['node', '--version'], 15)
runner = out / 'run-wasi.mjs'
runner.write_text("import { WASI } from 'node:wasi'; import { readFile } from 'node:fs/promises';\n"
                  "const wasi = new WASI({version:'preview1',args:['EnvironmentProbe'],env:{},preopens:{}});\n"
                  "const module = await WebAssembly.compile(await readFile(process.argv[2]));\n"
                  "const instance = await WebAssembly.instantiate(module,wasi.getImportObject());wasi.start(instance);\n")
for mode in ['native', 'wasm', 'wasm-embedded']:
    build = out / ('engine-' + mode)
    command = ['xcrun', 'swift', 'build', '--package-path', str(fixture), '--build-path', str(build), '--product', 'EnvironmentProbe', '--jobs', '4']
    if mode != 'native':
        sdk = 'swift-6.4.0-RELEASE_' + mode
        assert sdk in sdks.splitlines()
        command += ['--swift-sdk', sdk]
    if mode == 'wasm-embedded':
        command += ['-Xswiftc', '-whole-module-optimization', '-Xswiftc', '-Onone', '-Xlinker', '-lswiftUnicodeDataTables']
    run(mode + '-build', command)
    binary = next(build.glob('**/debug/EnvironmentProbe' + ('.wasm' if mode != 'native' else '')))
    run(mode + '-runtime', [str(binary)] if mode == 'native' else ['node', str(runner), str(binary)], 20)
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
          for name in targets for p in sorted((ROOT / 'Sources' / name).rglob('*.swift'))}
(out / 'portable-evidence.json').write_text(json.dumps(dict(hashes=hashes, commands=records), indent=2))
