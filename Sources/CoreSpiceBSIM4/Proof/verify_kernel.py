"""Bounded standalone C behavior and sanitizer verification, without SwiftPM."""
from pathlib import Path
import hashlib,json,subprocess,sys,time
root=Path(__file__).resolve().parent.parent
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
sources=sorted((root/'Kernel').glob('*.c'))
commands=[('library',['clang','-std=gnu17','-O0','-g','-fPIC','-dynamiclib','-I'+str(root/'Kernel'),*map(str,sources),'-o',str(out/'libKernel.dylib')]),
          ('sanitizer-build',['clang','-std=gnu17','-O0','-g','-fsanitize=address,undefined','-fno-sanitize-recover=all','-I'+str(root/'Kernel'),*map(str,sources),str(root/'Proof/kernel_probe.c'),'-o',str(out/'sanitizer')]),
          ('sanitizer-run',[str(out/'sanitizer')])]
evidence=[]
for label,command in commands:
 start=time.monotonic();r=subprocess.run(command,capture_output=True,text=True,timeout=30)
 (out/(label+'.log')).write_text(r.stdout+r.stderr)
 evidence.append({'stage':label,'command':command,'exitCode':r.returncode,'seconds':time.monotonic()-start})
 r.check_returncode()
 if label=='sanitizer-run':print(r.stdout,end='')
(out/'standalone.json').write_text(json.dumps({'runs':evidence,'sourceSHA256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources+[root/'Proof/kernel_probe.c',root/'include/CoreSpiceBSIM4.h']}},indent=2)+'\n')
