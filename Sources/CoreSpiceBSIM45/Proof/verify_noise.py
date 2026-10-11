"""Pinned original noise/host primitives and independent Native CPU proof."""
from pathlib import Path
from decimal import Decimal,localcontext
import argparse,hashlib,json,math,os,re,signal,subprocess,tarfile,time
p=argparse.ArgumentParser();p.add_argument('--original',type=Path,required=True);p.add_argument('--spice-archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--fixtures',type=int,default=596);a=p.parse_args()
a.original=a.original.resolve();root=Path(__file__).resolve().parents[3];module=root/'Sources/CoreSpiceBSIM45';k=module/'Kernel';proof=module/'Proof';out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
report=dict(status='running',scope='Native CPU B45-5 C noise only; no public Devices/Analysis or portable numerical adoption',commands=[])
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(label,args,limit=60):
 start=time.monotonic();proc=subprocess.Popen([str(x)for x in args],cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
 try:output=proc.communicate(timeout=limit)[0]
 except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.communicate();raise
 (out/(label+'.log')).write_text(output);report['commands'].append(dict(label=label,command=[str(x)for x in args],exitCode=proc.returncode,seconds=round(time.monotonic()-start,3)))
 print(label,proc.returncode,round(time.monotonic()-start,3),flush=True)
 if proc.returncode:raise RuntimeError(output[-5000:])
 return output
def build(name,files,includes,flags=()):
 binary=out/name;run('build-'+name,['clang','-std=gnu17','-Wno-deprecated-non-prototype',*flags,*['-I'+str(x)for x in includes],*files,'-o',binary],120);return binary
try:
 manifest=json.loads((k/'upstream.json').read_text())
 for name,hashes in manifest['files'].items():
  assert digest(a.original/name)==hashes['originalSHA256'];assert digest(k/name)==hashes['adaptedSHA256']
 report['sourceSHA256']={str(x.relative_to(root)):digest(x)for x in sorted(module.rglob('*'))if x.suffix in ('.c','.h','.inc','.py')}
 sources=sorted(k.glob('*.c'));shim=out/'reference-shim';shim.mkdir(exist_ok=True)
 compat=(k/'compat.h').read_text().replace('#include "../include/CoreSpiceBSIM45.h"','#include "CoreSpiceBSIM45.h"')
 compat=re.sub(r'^int BSIM4(?:NumFingerDiff|PAeffGeo|RdseffGeo|RdsEndIso|RdsEndSha)\([^\n]+\);\n','',compat,flags=re.M)
 compat=compat.replace('typedef void Ndata;', '''typedef struct {double freq,lstFreq,delFreq,outNoiz,inNoise,GainSqInv,lnGainInv,lnFreq,lnLastFreq,delLnFreq;int outNumber,numPlots,prtSummary;double *outpVector;IFuid *namelist;} Ndata;
typedef struct {double NstartFreq;int NStpsSm;} NOISEAN;
typedef void GENERIC;
#define N_DENS 1
#define INT_NOIZ 2
#define N_OPEN 1
#define N_CALC 2
#define N_CLOSE 3
#define LNLSTDENS 0
#define OUTNOIZ 1
#define INNOIZ 2
#define N_MXVLNTH 64
#define N_INTFTHRESH 1e-10
#define N_INTUSELOG 1e-10
#define UID_OTHER 0
#define trealloc realloc
''')
 compat=compat.replace('double *CKTrhs,*CKTrhsOld,','void *CKTcurJob; double *CKTirhs; double *CKTrhs,*CKTrhsOld,')
 extra='''
typedef struct JOB {const char *JOBname;struct JOB *JOBnextJob;} JOB;
typedef struct {JOB *jobs;} TSKtask;
typedef struct {TSKtask *ci_curTask;} ReferenceCircuit;extern ReferenceCircuit *ft_curckt;
typedef struct {void (*IFerror)(int,const char *,IFuid *);int (*IFnewUid)();} ReferenceFrontend;extern ReferenceFrontend *SPfrontEnd;
#define ERR_FATAL 1
static inline int CKTdltNNum(CKTcircuit *c,int n){return 0;}
int BSIM4NumFingerDiff(double,int,double *,double *,double *,double *);
int BSIM4PAeffGeo(double,int,int,double,double,double,double,double *,double *,double *,double *);
int BSIM4RdseffGeo(double,int,int,int,double,double,double,double,double,int,double *);
int BSIM4RdsEndIso(double,double,double,double,double,double,int,int,double *);
int BSIM4RdsEndSha(double,double,double,double,double,double,int,int,double *);
int BSIM4noise(int,int,GENmodel *,CKTcircuit *,Ndata *,double *);
'''
 (shim/'compat.h').write_text(compat.replace('#endif',extra+'\n#endif'))
 for name in {x.name for x in k.glob('*.h')}|{'fteconst.h','iferrmsg.h'}:
  if name not in ['compat.h','bsim4def.h','bsim4ext.h']:(shim/name).write_text('#include "compat.h"\n')
 assert digest(a.spice_archive)=='1476e158994701c5ee186fe597e056017067512cfc50025ed2f562d485a0254c'
 report['spiceArchiveSHA256']=digest(a.spice_archive);primitives=[]
 with tarfile.open(a.spice_archive) as tar:
  for name,sha in [('nevalsrc.c','c544ab1421f2a23e7ed4bf45b877dca97b469dde99f875d86392a78e91f264e0'),('ninteg.c','9b89c061e9ffa524b86c236877a0928394b20fffea23bae62a86271bafd6e7d7')]:
   data=tar.extractfile('spice3f5-73335519d0d7046c754c652569258c5ff1107cf4/src/lib/ckt/'+name).read();assert hashlib.sha256(data).hexdigest()==sha
   path=out/name;path.write_bytes(data);primitives.append(path)
 report['originalPrimitiveSHA256']={x.name:digest(x)for x in primitives}
 originals=[a.original/name for name in ['b4mpar.c','b4par.c','b4set.c','b4temp.c','b4check.c','b4geo.c','b4ld.c','b4noi.c']]
 oracle=build('original',originals+primitives+[proof/'noise_reference.c'],[a.original,shim,module/'include'],['-O2','-DORIGINAL_REFERENCE'])
 production=build('production',sources+[proof/'noise_reference.c'],[k,module/'include'],['-O2'])
 originalText=run('original-runtime',[oracle,a.fixtures]);productionText=run('production-runtime',[production,a.fixtures])
 topology=lambda t:[line for line in t.splitlines()if line.startswith('TOPO ')]
 assert topology(originalText)==topology(productionText)
 values=lambda t:[line.split()[1:]for line in t.splitlines()if line.startswith('NOISE ')]
 old=values(originalText);new=values(productionText);assert len(old)==len(new)==a.fixtures*4*7*5
 errors=[];correctedCoefficients=0;floorIntegrals=0;floorAffected={}
 for x,y in zip(old,new):
  assert x[:4]==y[:4] and len(x)==len(y)==33
  key=tuple(x[:3]);affected=floorAffected.setdefault(key,set())
  for source in range(13):
   if 0<float(x[4+source])<1e-38:affected.add(source)
  for n,(left,right)in enumerate(zip(x[4:],y[4:])):
   left=float(left);right=float(right);assert math.isfinite(left) and math.isfinite(right) and left>=0 and right>=0
   absolute=1e-32 if n<14 else 1e-36 if n<28 else 1e-18
   if abs(left-right)<=absolute+2e-7*max(abs(left),abs(right)):continue
   # Raw mode-1 channel power uses corrected static gm/gmb/gds; only ID/total
   # may differ. The untouched original noise is separately compared with the
   # qualified coefficients, without a waiver.
   if int(x[1])>=2 and n in (8,13,22,27,28):correctedCoefficients+=1
   elif 14<=n<27 and n-14 in affected:floorIntegrals+=1
   elif n in (27,28) and affected:floorIntegrals+=1
   else:errors.append((x[:4],n,left,right))
 report['qualifiedCoefficientDifferences']=correctedCoefficients;report['originalLogFloorIntegralDifferences']=floorIntegrals
 report['referencePolicy']='Raw original mode-1 ID/total derivative-coefficient differences and N_MINLOG integral artifacts are separately counted; coefficient-isolated original PSD and independent analytic source/integral laws must pass without waivers.'
 report['originalReferenceCases']=len(old);report['unexpectedReferenceDifferences']=errors[:30];report['unexpectedReferenceDifferenceCount']=len(errors)
 report['oracleSourceSHA256']={x.name:digest(x)for x in originals};assert not errors,errors[:10]
 # Compile untouched noise with a separate symbol and a local original CKT;
 # its model/instance copies isolate nVar while retaining qualified coefficients.
 coefficientShim=out/'coefficient-shim';coefficientShim.mkdir(exist_ok=True)
 for header in shim.glob('*.h'):
  text=header.read_text().replace('#define BSIM4noise cs_bsim45_noise','#define BSIM4noise cs_bsim45_oracle_noise').replace('#define Eval1ovFNoise cs_bsim45_Eval1ovFNoise','#define Eval1ovFNoise cs_bsim45_oracle_Eval1ovFNoise')
  (coefficientShim/header.name).write_text(text)
 objects=[]
 for name,path in [('noise',a.original/'b4noi.c'),('primitive',primitives[0]),('integral',primitives[1]),('wrapper',proof/'noise_coefficient_reference.c')]:
  obj=out/(name+'-oracle.o');run('build-'+name+'-oracle',['clang','-std=gnu17','-Wno-deprecated-non-prototype','-O2','-I'+str(a.original),'-I'+str(coefficientShim),'-I'+str(module/'include'),'-c',path,'-o',obj]);objects.append(obj)
 if (proof/'noise.c').exists():
  independent=build('noise',[x for x in sources if x.name!='PreparationOwner.c']+[proof/'noise.c']+objects,[k,module/'include'],['-O2','-DCOEFFICIENT_REFERENCE'])
  report['independentOutput']=run('independent-runtime',[independent,a.fixtures])
  highPrecision=0
  with localcontext() as context:
   context.prec=100
   for line in report['independentOutput'].splitlines():
    parts=line.split()
    if parts[0]=='PRIMITIVE':
     x,y,g,actual=map(lambda x:Decimal.from_float(float(x)),parts[1:]);expected=(x-y)**2*4*Decimal('1.3806226e-23')*Decimal('300.15')*g
    elif parts[0]=='INTEGRAL':
     lo,hi,s0,s1,actual=map(lambda x:Decimal.from_float(float(x)),parts[1:]);span=(hi/lo).ln();exponent=(s1/s0).ln()/span+1
     expected=s0*lo*span if abs(exponent)<Decimal('1e-80') else s0*lo*((exponent*span).exp()-1)/exponent
    else:continue
    assert abs(actual/expected-1)<Decimal('1e-12'),line;highPrecision+=1
  assert highPrecision==5;report['highPrecisionCases']=highPrecision
  sanitized=build('noise-sanitized',[x for x in sources if x.name!='PreparationOwner.c']+[proof/'noise.c'],[k,module/'include'],['-O0','-g','-fsanitize=address,undefined'])
  report['sanitizedOutput']=run('sanitized-runtime',[sanitized,a.fixtures],120)
 else:raise RuntimeError('Independent proof is required before qualification')
 report['status']='passed'
except BaseException as error:report['status']='failed';report['failure']=str(error);raise
finally:(out/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
