"""Standalone exact-source preparation proof; no external simulator or GPU."""
from pathlib import Path
import argparse, hashlib, json, math, os, re, signal, subprocess, time
p=argparse.ArgumentParser();p.add_argument('--original',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[3];module=root/'Sources/CoreSpiceBSIM45';k=module/'Kernel';proof=module/'Proof';out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
commands=[];report=dict(status='running',preparationComparisonTolerance=dict(relative=2e-13,absolute=1e-20,scope='prepared scalar values in matching SI units; topology exact'),scope='Native CPU preparation only; no numerical execution or physical qualification',commands=commands)
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(label,args,cwd=out,limit=120):
 start=time.monotonic();process=subprocess.Popen([str(x)for x in args],cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 try:output=process.communicate(timeout=limit)[0]
 except subprocess.TimeoutExpired:
  os.killpg(process.pid,signal.SIGKILL);output=process.communicate()[0];raise
 (out/(label+'.log')).write_text(output);commands.append(dict(label=label,command=[str(x)for x in args],exitCode=process.returncode,seconds=round(time.monotonic()-start,3)))
 (out/'verification.json').write_text(json.dumps(report,indent=2));print(label,process.returncode,round(time.monotonic()-start,3),flush=True)
 if process.returncode:raise RuntimeError(output[-6000:])
 return output
def build(label,files,includes,extra=()):
 binary=out/label
 run('build-'+label,['clang','-std=gnu17','-Wno-deprecated-non-prototype',*extra,*['-I'+str(x)for x in includes],*files,'-o',binary])
 return binary
try:
 manifest=json.loads((k/'upstream.json').read_text())
 for name,hashes in manifest['files'].items():
  assert digest(a.original/name)==hashes['originalSHA256'],name
  assert digest(k/name)==hashes['adaptedSHA256'],name
 report['sourceSHA256']={str(x.relative_to(root)):digest(x)for x in sorted(module.rglob('*'))if x.suffix in ('.c','.h','.inc','.py')}
 sources=sorted(k.glob('*.c'));other=[x for x in sources if x.name!='PreparationOwner.c']
 binary=build('ownership',other+[proof/'ownership.c'],[k,module/'include'],['-O0','-g','-fsanitize=address,undefined'])
 report['ownershipOutput']=run('ownership-runtime',[binary],limit=30)
 tables=build('tables',sources+[proof/'tables.c'],[k,module/'include'],['-O0'])
 actual=run('tables-runtime',[tables],limit=30)
 expected=json.loads((root/'tools/bsim45/schema.json').read_text())['parameters'];kinds={'real':1,'integer':2,'flag':3,'text':4,'vector':5}
 actual=[line.split() for line in actual.splitlines()]
 assert len(actual)==len(expected)==779
 for row,original in zip(actual,expected):
  assert row==[str(original['role']=='model' and 1 or 0),original['name'],str(original['selector']),str(kinds[original['kind']])],(row,original)
 report['compiledSchemaRecords']=len(actual)
 # Original C files are compiled without rewriting any setup/temp/check formulas.
 # This shim supplies only the original simulator services inside a separate process.
 shim=out/'reference-shim';shim.mkdir(exist_ok=True)
 compat=(k/'compat.h').read_text()
 compat=re.sub(r'^int BSIM4(?:NumFingerDiff|PAeffGeo|RdseffGeo|RdsEndIso|RdsEndSha)\([^\n]+\);\n','',compat,flags=re.M)
 compat=compat.replace('#include "../include/CoreSpiceBSIM45.h"','#include "CoreSpiceBSIM45.h"')
 compat=re.sub(r'^#define CONSTvt0.*$', '#define CONSTvt0 (1.3806226e-23 * 300.15 / 1.6021918e-19)', compat, flags=re.M)
 compat=re.sub(r'^#define CONSTroot2.*$', '#define CONSTroot2 sqrt(2.0)', compat, flags=re.M)
 compat=re.sub(r'^#define CONSTCtoK.*$', '#define CONSTCtoK 273.15', compat, flags=re.M)
 compat=compat.replace('#endif' ,'''
typedef struct JOB {const char *JOBname;struct JOB *JOBnextJob;} JOB;
typedef struct {JOB *jobs;} TSKtask;
typedef struct {TSKtask *ci_curTask;} ReferenceCircuit;
extern ReferenceCircuit *ft_curckt;
typedef struct {void (*IFerror)(int,const char *,IFuid *);} ReferenceFrontend;
extern ReferenceFrontend *SPfrontEnd;
#define ERR_FATAL 1
static inline int CKTdltNNum(CKTcircuit *c,int number){return 0;}
int BSIM4NumFingerDiff(double,int,double *,double *,double *,double *);
int BSIM4PAeffGeo(double,int,int,double,double,double,double,double *,double *,double *,double *);
int BSIM4RdseffGeo(double,int,int,int,double,double,double,double,double,int,double *);
int BSIM4RdsEndIso(double,double,double,double,double,double,int,int,double *);
int BSIM4RdsEndSha(double,double,double,double,double,double,int,int,double *);
#endif''')
 (shim/'compat.h').write_text(compat)
 for header in k.glob('*.h'):
  if header.name not in ['compat.h','bsim4def.h','bsim4ext.h']:(shim/header.name).write_text('#include "compat.h"\n')
 originalFiles=[a.original/name for name in ['b4mpar.c','b4par.c','b4set.c','b4temp.c','b4check.c','b4geo.c']]
 original=build('original',originalFiles+[proof/'reference.c'],[a.original,shim,module/'include'],['-O2','-DORIGINAL_REFERENCE'])
 production=build('production',sources+[proof/'reference.c'],[k,module/'include'],['-O2'])
 originalValues=[x.split()[1:]for x in run('original-runtime',[original],limit=30).splitlines()if x.startswith('CASE ')]
 productionValues=[x.split()[1:]for x in run('production-runtime',[production],limit=30).splitlines()if x.startswith('CASE ')]
 assert len(originalValues)==len(productionValues)==648
 for old,new in zip(originalValues,productionValues):
  assert old[:10]==new[:10],(old,new)
  for x,y in zip(old[10:],new[10:]):assert math.isclose(float(x),float(y),rel_tol=2e-13,abs_tol=1e-20),(old[0],x,y)
 report['originalReferenceCases']=648
 report['preparationComparisonTolerance']=dict(relative=2e-13,absolute=1e-20,scope='prepared scalar values in matching SI units; topology exact')
 # Every exported original function/table must have the release namespace.
 symbols=run('symbols',['nm','-gU',production],limit=30)
 assert not re.search(r'\b_BSIM4\w+',symbols)
 assert not re.search(r'\b_cs_bsim4_',symbols)
 later=root/'Sources/CoreSpiceBSIM4'
 coexist=build('coexistence',sources+sorted((later/'Kernel').glob('*.c'))+[proof/'coexistence.c'],[module/'include',later/'include'],['-O0','-g','-fsanitize=address,undefined'])
 report['coexistenceOutput']=run('coexistence-runtime',[coexist],limit=30)
 report['status']='passed'
except BaseException as error:report['status']='failed';report['failure']=str(error);raise
finally:(out/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
