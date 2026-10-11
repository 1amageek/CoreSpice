"""Exact-release transient proof: original integration, companions and lifecycle."""
from pathlib import Path
from decimal import Decimal, localcontext
import argparse,hashlib,json,math,os,re,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--original',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--spice-archive',type=Path,required=True);p.add_argument('--fixtures',type=int,default=596);a=p.parse_args()
a.original=a.original.resolve()
root=Path(__file__).resolve().parents[3];module=root/'Sources/CoreSpiceBSIM45';k=module/'Kernel';proof=module/'Proof';out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
report=dict(status='running',scope='Native CPU BE/TR/transient NQS only; no noise/public binding',commands=[])
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(label,args,limit=30):
 start=time.monotonic();proc=subprocess.Popen([str(x)for x in args],cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 try:output=proc.communicate(timeout=limit)[0]
 except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.communicate();raise
 (out/(label+'.log')).write_text(output);report['commands'].append(dict(label=label,command=[str(x)for x in args],exitCode=proc.returncode,seconds=round(time.monotonic()-start,3)))
 print(label,proc.returncode,round(time.monotonic()-start,3),flush=True)
 if proc.returncode:raise RuntimeError(output[-6000:])
 return output
def build(name,files,includes,flags=()):
 binary=out/name;run('build-'+name,['clang','-std=gnu17','-Wno-deprecated-non-prototype',*flags,*['-I'+str(x)for x in includes],*files,'-o',binary],limit=120);return binary
try:
 manifest=json.loads((k/'upstream.json').read_text())
 for name,hashes in manifest['files'].items():
  assert digest(a.original/name)==hashes['originalSHA256'];assert digest(k/name)==hashes['adaptedSHA256']
 report['sourceSHA256']={str(x.relative_to(root)):digest(x)for x in sorted(module.rglob('*'))if x.suffix in ('.c','.h','.inc','.py')}
 sources=sorted(k.glob('*.c'))
 shim=out/'reference-shim';shim.mkdir(exist_ok=True)
 compat=(k/'compat.h').read_text().replace('#include "../include/CoreSpiceBSIM45.h"','#include "CoreSpiceBSIM45.h"')
 compat=re.sub(r'^int BSIM4(?:NumFingerDiff|PAeffGeo|RdseffGeo|RdsEndIso|RdsEndSha)\([^\n]+\);\n','',compat,flags=re.M)
 compat=compat.replace('double CKTtemp,CKTnomTemp;','double CKTtemp,CKTnomTemp,CKTomega;')
 compat=compat.replace('#endif','''
typedef struct JOB {const char *JOBname;struct JOB *JOBnextJob;} JOB;
typedef struct {JOB *jobs;} TSKtask;
typedef struct {TSKtask *ci_curTask;} ReferenceCircuit;extern ReferenceCircuit *ft_curckt;
typedef struct {void (*IFerror)(int,const char *,IFuid *);} ReferenceFrontend;extern ReferenceFrontend *SPfrontEnd;
#define ERR_FATAL 1
static inline int CKTdltNNum(CKTcircuit *c,int n){return 0;}
int BSIM4NumFingerDiff(double,int,double *,double *,double *,double *);
int BSIM4PAeffGeo(double,int,int,double,double,double,double,double *,double *,double *,double *);
int BSIM4RdseffGeo(double,int,int,int,double,double,double,double,double,int,double *);
int BSIM4RdsEndIso(double,double,double,double,double,double,int,int,double *);
int BSIM4RdsEndSha(double,double,double,double,double,double,int,int,double *);
#endif''')
 (shim/'compat.h').write_text(compat)
 for header in k.glob('*.h'):
  if header.name not in ['compat.h','bsim4def.h','bsim4ext.h']:(shim/header.name).write_text('#include "compat.h"\n')
 # Unmodified SPICE3f5 primitive, pinned archive already used for preparation.
 import tarfile
 archive=a.spice_archive.resolve()
 assert digest(archive)=='1476e158994701c5ee186fe597e056017067512cfc50025ed2f562d485a0254c'
 report['spiceArchiveSHA256']=digest(archive)
 with tarfile.open(archive) as tar:
  name='spice3f5-73335519d0d7046c754c652569258c5ff1107cf4/src/lib/ni/niinteg.c'
  ni=tar.extractfile(name).read()
 assert hashlib.sha256(ni).hexdigest()=='f606207e30eb818bc86ac4ec911d427910e15f5adf1b4af026f1c0ab05f3de0b'
 (out/'niinteg.c').write_bytes(ni)
 report['originalNIintegrateSHA256']=hashlib.sha256(ni).hexdigest()
 extra='\n#define TRAPEZOIDAL 1\n#define GEAR 2\n#define E_ORDER 101\n#define E_METHOD 102\n#define MALLOC malloc\nstatic char *errMsg;\n'
 text=(shim/'compat.h').read_text().replace('int CKTmode,','int CKTintegrateMethod,CKTorder; double *CKTstate3,*CKTstate4,*CKTstate5,*CKTstate6; int CKTmode,')
 (shim/'compat.h').write_text(text.replace('#endif',extra+'\n#endif'))
 (shim/'util.h').write_text('#include "compat.h"\n')
 originals=[a.original/name for name in ['b4mpar.c','b4par.c','b4set.c','b4temp.c','b4check.c','b4geo.c','b4ld.c']]
 original=build('original',originals+[out/'niinteg.c',proof/'transient_reference.c'],[a.original,shim,module/'include'],['-O2','-DORIGINAL_REFERENCE'])
 production=build('production',sources+[proof/'transient_reference.c'],[k,module/'include'],['-O2'])
 oldText=run('original-runtime',[original,a.fixtures]);newText=run('production-runtime',[production,a.fixtures])
 old=[line.split()[1:]for line in oldText.splitlines()if line.startswith('TRAN ')]
 new=[line.split()[1:]for line in newText.splitlines()if line.startswith('TRAN ')]
 topology=[line.split()[1:]for line in oldText.splitlines()if line.startswith('TOPO ')]
 assert topology==[line.split()[1:]for line in newText.splitlines()if line.startswith('TOPO ')]
 assert len(topology)==a.fixtures and len(old)==len(new)==a.fixtures*12
 errors=[];corrections=0
 for x,y in zip(old,new):
  assert x[:2]==y[:2] and len(x)==len(y)==213
  meta=topology[int(x[0])];intrinsic={int(z)for z in meta[3:7]};resistive=intrinsic|{2,int(meta[7])}
  for n,(left,right)in enumerate(zip(x[2:],y[2:])):
   left=float(left);right=float(right);assert math.isfinite(left) and math.isfinite(right)
   absolute,relative=(1e-12,2e-6) if n<13 else (1e-10,2e-6) if n<182 else (1e-23,2e-7) if n-182 in (11,13,15,17,19,21,23,25,28) else (1e-12,2e-6) if n-182 in (12,14,16,18,20,22,24,26) else (1e-13,2e-7)
   if abs(left-right)<=absolute+relative*max(abs(left),abs(right)):continue
   row,col=divmod(n-13,13)
   # Only documented static-chain and NQS derivative/stable-charge corrections.
   # Every affected derivative is independently qualified at fixed tolerances.
   qnode=int(meta[10])
   correctedC=13<=n<182 and row in intrinsic|{qnode} and col in intrinsic
   correctedG=13<=n<182 and (float(meta[8])!=0 or float(meta[-1])>0) and row in resistive|{qnode} and col in intrinsic
   if correctedC or correctedG:corrections+=1
   else:errors.append((x[0],x[1],n,left,right))
 report['originalReferenceCases']=len(old);report['documentedDerivativeDifferences']=corrections
 report['derivativeDifferenceAuthority']='Kernel/DESIGN.md: static chain rules, stable NQS channel charge and XPART-disabled relaxation; independently differentiated without tolerance changes'
 report['unexpectedReferenceDifferenceCount']=len(errors);report['unexpectedReferenceDifferences']=errors[:30]
 report['oracleSourceSHA256']={x.name:digest(x)for x in originals}
 assert not errors,errors[:10]
 independent=build('transient',[x for x in sources if x.name!='PreparationOwner.c']+[proof/'transient.c'],[k,module/'include'],['-O2'])
 report['independentOutput']=run('independent-runtime',[independent,a.fixtures],limit=60)
 sanitized=build('transient-sanitized',[x for x in sources if x.name!='PreparationOwner.c']+[proof/'transient.c'],[k,module/'include'],['-O0','-g','-fsanitize=address,undefined'])
 report['sanitizedOutput']=run('sanitized-runtime',[sanitized,a.fixtures,'--memory-check'],limit=120)
 report['status']='passed'
except BaseException as error:report['status']='failed';report['failure']=str(error);raise
finally:(out/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
