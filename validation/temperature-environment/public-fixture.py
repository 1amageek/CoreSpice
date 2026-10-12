#!/usr/bin/env python3
"""Retain exact production/dependency declarations and only affected test targets.

No production source is copied or patched. The purpose is to avoid unrelated
Metal/photonic test discovery and test-bundle build/signing work.
"""
from pathlib import Path
import re
import argparse
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root=Path(__file__).resolve().parents[2]
fixture=args.output.resolve()/'public-component'
fixture.mkdir(exist_ok=True)
for name in ['Sources','Tests']:
 p=fixture/name
 if not p.exists(): p.symlink_to(root/name,target_is_directory=True)
s=(root/'Package.swift').read_text()
selected={'CoreSpiceNativeExecutionTests','CoreSpiceConditionEvaluationTests','CoreSpiceIOTests','CoreSpiceLoweringTests','CoreSpiceMOSResolutionTests','CoreSpiceMOSContractsTests','CoreSpiceMOSPreparationTests','CoreSpiceBSIM45IntegrationTests','CoreSpiceBSIM3IntegrationTests','CoreSpiceBSIM4IntegrationTests','CoreSpiceBSIM3NoiseTests','CoreSpiceBSIM4NoiseTests','CoreSpiceIRTests','CoreSpiceInitialConditionTests'}
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
 if name not in selected:
  while i<len(s) and s[i] in ' \t':i+=1
  if s[i:i+1]==',':i+=1
  spans.append((start,i))
for start,end in reversed(spans):s=s[:start]+s[end:]
(fixture/'Package.swift').write_text(s)
(fixture/'Package.resolved').write_bytes((root/'Package.resolved').read_bytes())
