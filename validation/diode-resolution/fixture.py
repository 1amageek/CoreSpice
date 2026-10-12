#!/usr/bin/env python3
"""Select owned tests while retaining exact production target and dependency declarations."""
from pathlib import Path
import argparse
import re
parser=argparse.ArgumentParser()
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--mode',choices=['public','resolution'],default='public')
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
fixture=args.output.resolve()/(args.mode+'-component')
fixture.mkdir(parents=True,exist_ok=True)
for name in ['Sources','Tests']:
 p=fixture/name
 if not p.exists():p.symlink_to(root/name,target_is_directory=True)
s=(root/'Package.swift').read_text()
selected={'CoreSpiceDiodeResolutionTests','CoreSpiceDiodeIntegrationTests','CoreSpiceConditionEvaluationTests','CoreSpiceIOTests','CoreSpiceLoweringTests','CoreSpiceMOSResolutionTests','CoreSpiceMOSContractsTests','CoreSpiceIRTests','CoreSpiceInitialConditionTests','CoreSpiceNativeExecutionTests','CoreSpiceParserSPICETests','CoreSpiceDiodeContractsTests'}
resolutionNames={'CoreSpiceEvaluationContracts','CoreSpiceDiodeContracts','CoreSpiceMOSContracts','CoreSpiceMOSResolution','CoreSpiceEvent','CoreSpiceIR','CoreSpiceParsedIR','CoreSpiceParser','CoreSpiceParserSPICE','CoreSpiceLowering','CoreSpiceDiodeResolutionTests'}
if args.mode == 'resolution':
 entries=[]
 for match in re.finditer(r'\.(?:testTarget|target)\(',s):
  start=match.start();i=match.end();depth=1;quote=False;escape=False
  while depth:
   c=s[i]
   if quote:
    if escape:escape=False
    elif c=='\\':escape=True
    elif c=='"':quote=False
   elif c=='"':quote=True
   elif c=='(':depth+=1
   elif c==')':depth-=1
   i+=1
  name=re.search(r'name:\s*"([^"]+)"',s[start:i]).group(1)
  if name in resolutionNames:entries.append(s[start:i])
 definitions=s.split('let package =')[0]
 s=definitions+'let package = Package(name: "DiodeD3Resolution", platforms: [.macOS(.v27)], dependencies: [circuiteFoundationDependency], targets: [\n'+',\n'.join(entries)+'])\n'
spans=[]
for match in re.finditer(r'\.testTarget\(',s):
 start=match.start();i=match.end();depth=1;quote=False;escape=False
 while depth:
  c=s[i]
  if quote:
   if escape:escape=False
   elif c=='\\':escape=True
   elif c=='"':quote=False
  elif c=='"':quote=True
  elif c=='(':depth+=1
  elif c==')':depth-=1
  i+=1
 name=re.search(r'name:\s*"([^"]+)"',s[start:i]).group(1)
 if args.mode == 'public' and name not in selected:
  while i<len(s) and s[i] in ' \t':i+=1
  if s[i:i+1]==',':i+=1
  spans.append((start,i))
for start,end in reversed(spans):s=s[:start]+s[end:]
(fixture/'Package.swift').write_text(s)
(fixture/'Package.resolved').write_bytes((root/'Package.resolved').read_bytes())
