#!/usr/bin/env python3
"""Run new D3 value construction/sharing/refusal on the exact three target baselines."""
from pathlib import Path
import argparse,json,os,subprocess,time
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
root=Path(__file__).resolve().parents[2];out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
fixture=out/'component';fixture.mkdir(exist_ok=True)
for name in ['CoreSpiceEvaluationContracts','CoreSpiceDiodeContracts']:
 p=fixture/'Sources'/name;p.parent.mkdir(parents=True,exist_ok=True)
 if not p.exists():p.symlink_to(root/'Sources'/name,target_is_directory=True)
p=fixture/'Sources'/'D3Probe';p.mkdir(exist_ok=True)
f=p/'ContractsProbe.swift'
if not f.exists():f.symlink_to(root/'validation/diode-resolution/ContractsProbe.swift')
(fixture/'Package.swift').write_text('''// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "DiodeD3Contracts", platforms: [.macOS(.v27)], targets: [
.target(name: "CoreSpiceEvaluationContracts", exclude: ["DESIGN.md", "Environment/DESIGN.md"]),
.target(name: "CoreSpiceDiodeContracts", dependencies: ["CoreSpiceEvaluationContracts"], exclude: ["DESIGN.md", "Input/DESIGN.md"]),
.executableTarget(name: "D3Probe", dependencies: ["CoreSpiceEvaluationContracts", "CoreSpiceDiodeContracts"])
])
''')
runner=out/'run-wasi.mjs';runner.write_text("import {WASI} from 'node:wasi';import {readFile} from 'node:fs/promises';const w=new WASI({version:'preview1',args:['D3Probe'],env:{},preopens:{}});const m=await WebAssembly.compile(await readFile(process.argv[2]));const i=await WebAssembly.instantiate(m,w.getImportObject());w.start(i);\n")
records=[];env=dict(os.environ)
def run(label,command,timeout=120):
 start=time.monotonic();result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=timeout)
 (out/(label+'.log')).write_text(result.stdout+result.stderr);records.append(dict(label=label,command=command,exit=result.returncode,seconds=time.monotonic()-start));(out/'commands.json').write_text(json.dumps(records,indent=2))
 if result.returncode:print((result.stdout+result.stderr)[-3000:]);raise SystemExit(label+' failed')
 print(label+': passed',flush=True);return result.stdout
assert 'Swift version 6.4 (swift-6.4-RELEASE)' in run('toolchain',['xcrun','swift','--version'],15)
sdks=run('sdks',['xcrun','swift','sdk','list'],15)
for mode in ['native','wasm','wasm-embedded']:
 build=out/mode;command=['xcrun','swift','build','--package-path',str(fixture),'--build-path',str(build),'--product','D3Probe','--jobs','4','--disable-index-store']
 if mode!='native':
  sdk='swift-6.4.0-RELEASE_'+mode;assert sdk in sdks.splitlines();command+=['--swift-sdk',sdk]
 if mode=='wasm-embedded':command+=['-Xswiftc','-whole-module-optimization','-Xswiftc','-Onone','-Xlinker','-lswiftUnicodeDataTables']
 run(mode+'-build',command)
 binary=next(build.glob('**/debug/D3Probe'+('.wasm' if mode!='native' else '')))
 assert 'D3-CONTRACTS-PASS' in run(mode+'-runtime',[str(binary)] if mode=='native' else ['node',str(runner),str(binary)],20)
