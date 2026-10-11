"""Exact-release AC proof: original oracle, physical identities and owner lifecycle."""
from pathlib import Path
from decimal import Decimal, localcontext
import argparse,hashlib,json,math,os,re,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--original',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--fixtures',type=int,default=580);a=p.parse_args()
a.original=a.original.resolve()
root=Path(__file__).resolve().parents[3];module=root/'Sources/CoreSpiceBSIM45';k=module/'Kernel';proof=module/'Proof';out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
report=dict(status='running',scope='Native CPU AC/frequency NQS only; no transient/noise/public binding',commands=[])
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
 originals=[a.original/name for name in ['b4mpar.c','b4par.c','b4set.c','b4temp.c','b4check.c','b4geo.c','b4ld.c','b4acld.c']]
 original=build('original',originals+[proof/'ac_reference.c'],[a.original,shim,module/'include'],['-O2','-DORIGINAL_REFERENCE'])
 production=build('production',sources+[proof/'ac_reference.c'],[k,module/'include'],['-O2'])
 oldText=run('original-runtime',[original,a.fixtures]);newText=run('production-runtime',[production,a.fixtures])
 old=[line.split()[1:]for line in oldText.splitlines()if line.startswith('AC ')]
 new=[line.split()[1:]for line in newText.splitlines()if line.startswith('AC ')]
 topology=[line.split()[1:]for line in oldText.splitlines()if line.startswith('TOPO ')]
 assert topology==[line.split()[1:]for line in newText.splitlines()if line.startswith('TOPO ')]
 assert len(topology)==a.fixtures and len(old)==len(new)==a.fixtures*7
 errors=[];corrections=0
 for x,y in zip(old,new):
  assert x[:2]==y[:2] and len(x)==len(y)==340
  meta=topology[int(x[0])];intrinsic={int(z)for z in meta[3:7]};resistive=intrinsic|{2,int(meta[7])}
  for n,(left,right)in enumerate(zip(x[2:],y[2:])):
   left=float(left);right=float(right);assert math.isfinite(left) and math.isfinite(right)
   if abs(left-right)<=1e-12+2e-6*max(abs(left),abs(right)):continue
   row,col=divmod(n%169,13)
   correctedC=row in intrinsic and col in intrinsic
   correctedG=float(meta[8])!=0 and row in resistive and col in intrinsic
   if correctedC or correctedG:corrections+=1
   else:errors.append((x[0],x[1],n,left,right))
 report['originalReferenceCases']=len(old);report['documentedStaticDerivativeDifferences']=corrections
 report['unexpectedReferenceDifferenceCount']=len(errors);report['unexpectedReferenceDifferences']=errors[:30]
 report['referencePolicy']='Raw original AC with original static coefficients: only documented B45-3 derivative footprints may differ. Unmodified original AC with qualified production coefficients is separately compared without any waiver.'
 report['admittanceTolerance']=dict(absoluteS=1e-12,relative=2e-6)
 report['oracleSourceSHA256']={x.name:digest(x)for x in originals}
 assert not errors,errors[:10]
 # Build the untouched original AC in isolation under a distinct symbol. Its
 # original structure layout is identical to production; only simulator headers
 # are adapted. This oracle has no static-equation correction ambiguity.
 oracleShim=out/'coefficient-shim';oracleShim.mkdir(exist_ok=True)
 for header in shim.glob('*.h'):
  text=header.read_text()
  if header.name=='compat.h':text=text.replace('#define BSIM4acLoad cs_bsim45_acLoad','#define BSIM4acLoad cs_bsim45_oracle_acLoad')
  (oracleShim/header.name).write_text(text)
 oracleObject=out/'original-ac.o'
 run('build-original-ac-object',['clang','-std=gnu17','-O2','-I'+str(a.original),'-I'+str(oracleShim),'-I'+str(module/'include'),'-c',a.original/'b4acld.c','-o',oracleObject])
 independent=build('ac',[x for x in sources if x.name!='PreparationOwner.c']+[proof/'ac.c',oracleObject],[k,module/'include'],['-O2','-DCOEFFICIENT_REFERENCE'])
 report['independentOutput']=run('independent-runtime',[independent,a.fixtures],limit=30)
 sanitized=build('ac-sanitized',[x for x in sources if x.name!='PreparationOwner.c']+[proof/'ac.c'],[k,module/'include'],['-O0','-g','-fsanitize=address,undefined'])
 with localcontext() as context:
  context.prec=100
  transfers=0
  for line in report['independentOutput'].splitlines():
   if not line.startswith('RELAX '):continue
   values=[Decimal.from_float(float(x))for x in line.split()[1:]]
   omega,tau,*actual=values;x=omega*tau;den=1+x*x
   expected=[1/den,x/den,omega*x/den]
   for left,right in zip(actual,expected):assert abs(left-right)<=Decimal.from_float(float.fromhex('0x0.0000000000001p-1022'))+Decimal('2e-14')*abs(right),(values,expected)
   transfers+=1
  assert transfers==36
 report['decimalTransferCases']=transfers
 report['sanitizedOutput']=run('sanitized-runtime',[sanitized,a.fixtures,'--memory-check'],limit=60)
 report['status']='passed'
except BaseException as error:report['status']='failed';report['failure']=str(error);raise
finally:(out/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
