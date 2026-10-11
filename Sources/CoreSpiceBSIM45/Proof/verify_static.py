"""Exact-release static proof, independent original oracle and physical invariants."""
from pathlib import Path
import argparse,hashlib,json,math,os,re,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--original',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--fixtures',type=int,default=580);a=p.parse_args()
a.original=a.original.resolve()
root=Path(__file__).resolve().parents[3];module=root/'Sources/CoreSpiceBSIM45';k=module/'Kernel';proof=module/'Proof';out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
report=dict(status='running',scope='Native CPU original static physical current/charge and full-node analytic Jacobians; no AC/transient/noise/public binding',commands=[])
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
 binary=out/name;run('build-'+name,['clang','-std=gnu17','-Wno-deprecated-non-prototype',*flags,*['-I'+str(x)for x in includes],*files,'-o',binary]);return binary
try:
 manifest=json.loads((k/'upstream.json').read_text())
 for name,hashes in manifest['files'].items():
  assert digest(a.original/name)==hashes['originalSHA256'];assert digest(k/name)==hashes['adaptedSHA256']
 report['sourceSHA256']={str(x.relative_to(root)):digest(x)for x in sorted(module.rglob('*'))if x.suffix in ('.c','.h','.inc','.py')}
 sources=sorted(k.glob('*.c'))
 binary=build('static',sources+[proof/'static.c'],[k,module/'include'],['-O2'])
 shim=out/'reference-shim';shim.mkdir(exist_ok=True)
 compat=(k/'compat.h').read_text().replace('#include "../include/CoreSpiceBSIM45.h"','#include "CoreSpiceBSIM45.h"')
 compat=re.sub(r'^int BSIM4(?:NumFingerDiff|PAeffGeo|RdseffGeo|RdsEndIso|RdsEndSha)\([^\n]+\);\n','',compat,flags=re.M)
 compat=compat.replace('double CKTtemp,CKTnomTemp;','double CKTtemp,CKTnomTemp,CKTomega;')
 compat=compat.replace('int CKTmode,CKTbypass,CKTnoncon;', 'int CKTmode,CKTbypass,CKTnoncon; double *CKTstates[3];')
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
 original=build('original',originals+[proof/'static_reference.c'],[a.original,shim,module/'include'],['-O2','-DORIGINAL_REFERENCE'])
 production=build('production',sources+[proof/'static_reference.c'],[k,module/'include'],['-O2'])
 oldText=run('original-runtime',[original,a.fixtures]);newText=run('production-runtime',[production,a.fixtures])
 old=[line.split()[1:]for line in oldText.splitlines()if line.startswith('STATIC ')]
 new=[line.split()[1:]for line in newText.splitlines()if line.startswith('STATIC ')]
 topology=[line.split()[1:]for line in oldText.splitlines()if line.startswith('TOPO ')]
 assert topology==[line.split()[1:]for line in newText.splitlines()if line.startswith('TOPO ')]
 assert len(topology)==a.fixtures and len(old)==len(new)==a.fixtures*7
 errors=[];corrections={'conductance':0,'capacitance':0};examples=[]
 for x,y in zip(old,new):
  assert x[:2]==y[:2] and len(x)==len(y)==366
  meta=topology[int(x[0])];intrinsic={int(z)for z in meta[3:7]};resistive=intrinsic|{2,int(meta[7])}
  for n,(left,right)in enumerate(zip(x[2:],y[2:])):
   absolute=1e-13 if n<13 else 1e-23 if n<26 else 1e-10 if n<195 else 1e-20
   left=float(left);right=float(right);assert math.isfinite(left) and math.isfinite(right)
   if math.isclose(left,right,rel_tol=2e-7,abs_tol=absolute):continue
   matrix=n-26 if n<195 else n-195;row,col=divmod(matrix,13)
   # Only the documented derivative corrections may differ. Original I/Q laws
   # and every row/column outside their affected physical nodes remain strict.
   correctedG=26<=n<195 and float(meta[8])!=0 and row in resistive and col in intrinsic
   correctedC=n>=195 and row in intrinsic and col in intrinsic
   if correctedG or correctedC:
    key='conductance' if correctedG else 'capacitance';corrections[key]+=1
    if len(examples)<12:examples.append(dict(fixture=int(x[0]),point=int(x[1]),matrix=key,row=row,column=col,original=left,corrected=right))
   else:errors.append((x[0],x[1],n,left,right))
 report['originalReferenceCases']=len(old);report['unexpectedReferenceDifferences']=errors[:30];report['unexpectedReferenceDifferenceCount']=len(errors)
 report['documentedDerivativeDifferences']=corrections;report['correctionExamples']=examples
 report['referencePolicy']='All I/Q, topology and unaffected G/C must match original; documented intrinsic chain corrections additionally require independent finite differences at every physical node.'
 report['referenceTolerance']=dict(relative=2e-7,currentA=1e-13,chargeC=1e-23,conductanceS=1e-10,capacitanceF=1e-20)
 report['finiteDifferenceTolerance']=dict(relative=2e-4,conductanceS=1e-10,capacitanceF=1e-20,centralStepsV=[1e-2,3e-3,1e-3,3e-4,1e-4,1e-5,1e-6],minimumAdjacentPassingSteps=2,zeroVDS='Second-order forward-branch one-sided D/S differences; central for other columns')
 report['oracleSourceSHA256']={x.name:digest(x)for x in originals}
 assert not errors,errors[:10]
 if a.fixtures>=18:assert all(corrections.values())
 report['independentOutput']=run('independent-runtime',[binary,0,a.fixtures],limit=60)
 sanitized=build('static-sanitized',sources+[proof/'static.c'],[k,module/'include'],['-O0','-g','-fsanitize=address,undefined'])
 report['sanitizedOutput']=run('sanitized-runtime',[sanitized,0,a.fixtures,"--memory-check"],limit=30)
 ownership=build('static-ownership',[x for x in sources if x.name!='PreparationOwner.c']+[proof/'static_ownership.c'],[k,module/'include'],['-O0','-g','-fsanitize=address,undefined'])
 report['ownershipOutput']=run('ownership-runtime',[ownership],limit=30)
 report['status']='passed'
except BaseException as error:report['status']='failed';report['failure']=str(error);raise
finally:(out/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
