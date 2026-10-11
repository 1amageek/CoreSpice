"""Reproduce the exclusive static isolation of the official nested BSIM4 4.5.0."""
from pathlib import Path
import hashlib, json, re, sys
source = Path(sys.argv[1]); target = Path(__file__).resolve().parent
check = '--check' in sys.argv[2:]
def publish(path, data):
 if isinstance(data,str): data=data.encode()
 if check: assert path.read_bytes()==data,path
 else: path.write_bytes(data)
files = ['b4.c','b4mpar.c','b4par.c','b4set.c','b4temp.c','b4check.c','b4geo.c','b4ld.c','bsim4def.h','bsim4ext.h','b4acld.c']
geometry = ['BSIM4NumFingerDiff','BSIM4PAeffGeo','BSIM4RdseffGeo','BSIM4RdsEndIso','BSIM4RdsEndSha']
manifest = dict(release='4.5.0', adaptation='noise-frequency-scaling-v1.noise-flicker-cancellation-v1.noise-v1.noise-power-integral-v1.nqs-disabled-charge-derivative-v1.nqs-channel-charge-v1.transient-v1.ac-v1.ac-qs-authority-v1.ac-nqs-stable-v1.static-v1.sc-selector-v1.cap0-chain-rule-v1.cv-drain-body-v1.ud-chain-rule-v1.spice3f5-constants',
 archiveURL='https://www.bsim.berkeley.edu/BSIM4/BSIM450.zip',
 archiveSHA256='2d0bc2496bf9b9c18dd2f790c679bfa76426fcac4a1691688fcb6a80a590f3e8',
 nestedSHA256='d94a1df9367d565787f555cc8ce6bd515a34f4d1752fb1da91df6ab54c56e39f',
 corrections=['noise-frequency-scaling-v1','noise-flicker-cancellation-v1','nqs-disabled-charge-derivative-v1','nqs-channel-charge-v1','sc-selector-v1','cap0-chain-rule-v1','cv-drain-body-v1','ud-chain-rule-v1','ac-nqs-stable-v1','ac-qs-authority-v1'],
 files={}, diagnosticSites={})
fields = {}
original_diagnostics = []
last_diagnostic = -1
for name, role, owner in [('b4par.c',0,'here'),('b4mpar.c',1,'mod')]:
 text = (source/name).read_text()
 for m in re.finditer(r'case\s+(BSIM4_\w+)\s*:\s*'+owner+r'->(BSIM4\w+)\s*=',text):
  fields[(role,m[2])] = m[1]
def diagnostic_inside(text):
 inside = text[text.index('(')+1:text.rindex(')')]
 return inside[inside.index(',')+1:] if text.startswith('fprintf') else inside

def diagnose(match, name, original):
 global last_diagnostic
 text = match[0]; inside = text[text.index('(')+1:text.rindex(')')]
 if text.startswith('fprintf'): inside = inside[inside.index(',')+1:]
 fmt = re.match(r'\s*("(?:[^"\\]|\\.)*")',inside)
 assert fmt, (name,text)
 literal = fmt[1]
 # Banners do not diagnose a physical condition and need no capacity.
 if name == 'b4check.c' and any(x in literal for x in ['Berkeley Short Channel','Developed by','PARAMETER CHECKING','Model =']): return ';'
 if literal in ['"\\n"']: return ';'
 code = 'CS_BSIM45_DIAG_FATAL' if 'Fatal' in literal else 'CS_BSIM45_DIAG_WARNING'
 role = -1; selector = '0'; value = '0.0'
 after = inside[fmt.end():]
 field = re.match(r'\s*,\s*(here|model|pParam)->(BSIM4\w+)\s*(?:,|$)',after)
 if field:
  role = 0 if field[1] == 'here' else 1
  selector = fields.get((role,field[2]),'0')
  if selector != '0': value = '(double)'+field[1]+'->'+field[2]
  else: role = -1
 fingerprint = text[:text.index('(')].strip()+re.sub(r'\s+', '', inside)
 candidates = [(index, line) for index, (line, content) in enumerate(original_diagnostics)
               if index > last_diagnostic and content == fingerprint]
 assert candidates, (name, inside)
 last_diagnostic, line = candidates[0]
 site = files.index(name)*10000 + line
 manifest['diagnosticSites'][str(site)] = dict(file=name, line=line, role=role, selector=selector, code=code)
 return f'cs_diagnostic(ckt, {site}, {code}, {role}, {selector}, {value}, {inside})'
for name in files:
 original = (source/name).read_bytes(); s = original.decode()
 original_diagnostics = [(s[:m.start()].count('\n')+1, m[0][:m[0].index('(')].strip()+re.sub(r'\s+', '', diagnostic_inside(m[0])))
                         for m in re.finditer(r'\b(?:fprintf|printf)\s*\((?:"(?:[^"\\]|\\.)*"|[^";])*\)', s)]
 last_diagnostic = -1
 if name == 'b4.c':
  s = s[:s.index('char *BSIM4names')].replace('IFparm BSIM4','const IFparm BSIM4')
  s, count = re.subn(r'("sc",\s*)BSIM4_SCA\b', r'\1BSIM4_SC', s)
  assert count == 1
  s += '\nconst int BSIM4pTSize=NUMELEMS(BSIM4pTable);\nconst int BSIM4mPTSize=NUMELEMS(BSIM4mPTable);\n'
 if name == 'b4set.c':
  start=s.index('JOB   *job;'); end=s.index('    /*  loop through all',start)
  s=s[:start]+'noiseAnalGiven = ckt->noiseRequested;\n\n'+s[end:]
  # Local node/matrix storage is part of the owner, not a simulator node registry.
  s=s[:s.index('\nint\nBSIM4unsetup')]
 if name == 'b4check.c':
  s=s.replace('FILE *fplog;','').replace('if ((fplog = fopen("bsim4.out", "w")) != NULL)','/* Checks run regardless of filesystem/diagnostic availability. */')
  s=re.sub(r'\bprintf\((?:"(?:[^"\\]|\\.)*"|[^";])*\);',';',s)
  s=s.replace('fclose(fplog);','')
  start=s.index('    else\n    {   fprintf(stderr, "Warning: Can'); end=s.index('    return(Fatal_Flag);',start)
  s=s[:start]+s[end:]
 if name in ['b4set.c','b4temp.c','b4check.c','b4geo.c']:
  # Original diagnostics become bounded structured records; they never gate checks.
  diagnostic_source=s
  s=re.sub(r'\b(?:fprintf|printf)\s*\((?:"(?:[^"\\]|\\.)*"|[^";])*\)',lambda m: diagnose(m,name,diagnostic_source),s)
  fatal_pattern = r'\(\*\(SPfrontEnd->IFerror\)\)\s*\(ERR_FATAL,'
  fatal_lines = iter(original.decode()[:m.start()].count('\n')+1 for m in re.finditer(fatal_pattern, original.decode()))
  def fatal_site(match):
   line = next(fatal_lines)
   site = files.index(name)*10000+line
   manifest['diagnosticSites'][str(site)] = dict(file=name,line=line,role=-1,selector='0',code='CS_BSIM45_DIAG_FATAL')
   return f'cs_fatal(ckt, {site},'
  s=re.sub(fatal_pattern,fatal_site,s)
  s=s.replace('malloc(','cs_allocate_size(ckt,')
  for function in geometry:
   s=re.sub(r'\b'+function+r'\((?!\))',function+'(ckt, ',s)
  if name == 'b4geo.c':
   for function in geometry:
    s,count=re.subn(r'('+function+r'\(ckt, [^)]*\)\n)',r'\1CKTcircuit *ckt;\n',s)
    assert count == 1,(function,count)
 if name == 'b4ld.c':
  # Retain channel-only expressions before accumulation/depletion cancellation.
  declaration='double stableChannelCharge=0, stableChannelGate=0, stableChannelDrain=0, stableChannelBody=0, stableSourceGate=0, stableSourceDrain=0, stableSourceBody=0;'
  s=s.replace('register BSIM4instance *here;', 'register BSIM4instance *here;\n'+declaration)
  cap1='qgate += Qac0 + Qsub0;'
  cap2='qgate += Qac0 + Qsub0 - qbulk;'
  for tag,channel,cg,cd,cb in [(cap1,'qgate+qbulk','Cgg1+Cbg1','Cgd1+Cbd1','Cgb1+Cbb1'),(cap2,'qgate','Cgg1','Cgd1','Cgb1')]:
   assert s.count(tag)==1
   capture=f'stableChannelCharge={channel}; stableChannelGate={cg}; stableChannelDrain={cd}; stableChannelBody=({cb})*dVbseff_dVb; stableSourceGate=Csg; stableSourceDrain=Csd; stableSourceBody=Csb*dVbseff_dVb;\n                  '
   s=s.replace(tag,capture+tag)
  # These two drains are the CAPMOD=1/2 paths; CAPMOD=0 stays original.
  tag='qdrn = -(qgate + qbulk + qsrc);'
  assert s.count(tag)==3
  s=s.replace(tag,'qdrn = -stableChannelCharge - qsrc;',2)
  tag='here->BSIM4qsrc = -(qgate + qbulk + qdrn);'
  s=s.replace(tag,tag+'\n          if(model->BSIM4capMod>=1) {\n              here->BSIM4qsrc=qsrc;\n              here->BSIM4cdgb=-stableChannelGate-stableSourceGate;\n              here->BSIM4cddb=-stableChannelDrain-stableSourceDrain;\n              here->BSIM4cdbb=-stableChannelBody-stableSourceBody;\n              here->BSIM4cdsb=-(here->BSIM4cdgb+here->BSIM4cddb+here->BSIM4cdbb);\n              here->BSIM4csgb=stableSourceGate;here->BSIM4csdb=stableSourceDrain;here->BSIM4csbb=stableSourceBody;\n              here->BSIM4cssb=-(stableSourceGate+stableSourceDrain+stableSourceBody);\n          }\n')
  tag='CoxWL = model->BSIM4coxe * pParam->BSIM4weffCV * here->BSIM4nf'
  nqs=s.index('/* NQS begins */');position=s.index(tag,nqs)
  s=s[:position]+'if(model->BSIM4capMod>=1) {\n                  here->BSIM4qchqs=qcheq=-stableChannelCharge;\n                  here->BSIM4cqgb=-stableChannelGate;here->BSIM4cqdb=-stableChannelDrain;\n                  here->BSIM4cqbb=-stableChannelBody;here->BSIM4cqsb=stableChannelGate+stableChannelDrain+stableChannelBody;\n              }\n              '+s[position:]

  tag='T0 = qdef * ScalingFactor / CoxWL;'
  assert s.count(tag)==2
  # XPART<0 sets gtau=0, so its voltage derivative must also be zero.
  s=s.replace(tag,'T0 = model->BSIM4xpart<0 ? 0.0 : qdef * ScalingFactor / CoxWL;')

  start=s.index('else if (model->BSIM4capMod == 0)');end=s.index('} /* end of capMod=0 */',start)
  block=s[start:end]
  assert block.count('if (Vbseff < 0.0)') == 1
  block=block.replace('if (Vbseff < 0.0)', 'double cvBodyChain = dVbseff_dVb;\n              if (Vbseff < 0.0)',1)
  block=block.replace('dVbseff_dVb = -dPhis_dVb;', 'dVbseff_dVb = -dPhis_dVb * cvBodyChain;')
  block=block.replace('dVth_dVb = pParam->BSIM4k1ox * dsqrtPhis_dVb;', 'dVth_dVb = pParam->BSIM4k1ox * dsqrtPhis_dVb * cvBodyChain;')
  block=block.replace('dAbulkCV_dVb = pParam->BSIM4abulkCVfactor * dAbulk0_dVb;', 'dAbulkCV_dVb = pParam->BSIM4abulkCVfactor * dAbulk0_dVb * cvBodyChain;')
  assert block.count('dVdsat_dVg = dVgs_eff_dVg / AbulkCV;') == 1
  block=block.replace('dVdsat_dVg = dVgs_eff_dVg / AbulkCV;', 'dVdsat_dVg = 1.0 / AbulkCV;')
  # This drain derivative is already with respect to raw Vg, unlike T7 and T0.
  assert block.count('T12 = (-T7 * dAlphaz_dVg - here->BSIM4cdgb\n') == 1
  block,count=re.subn(r'T12 = \(-T7 \* dAlphaz_dVg - here->BSIM4cdgb\s*- T0 \* dVdsat_dVg\) \* dVgs_eff_dVg;', 'T12 = (-T7 * dAlphaz_dVg - T0 * dVdsat_dVg)\\n                              * dVgs_eff_dVg - here->BSIM4cdgb;',block)
  assert count == 1
  s=s[:start]+block+s[end:]
  old='dVdseffCV_dVb = dT0_dVb * (1.0 - T5) + T5 * dT1_dVb;'
  assert s.count(old) == 2
  s=s.replace(old,'dVdseffCV_dVb = dT0_dVb * (T4 - T5) + T5 * dT1_dVb;')

  start=s.index('/* Mobility calculation */');end=s.index('/* Saturation Drain Voltage',start)
  block=s[start:end]
  old='dDenomi_dVd = dDenomi_dVg * 2.0 * dVth_dVd;'
  assert block.count(old) == 2
  block=block.replace(old,'dDenomi_dVd = (dDenomi_dVg * 2.0 + 2.0 * pParam->BSIM4ud * Vth / (T3 * T3)) * dVth_dVd;')
  old='dDenomi_dVb = dDenomi_dVg * 2.0 * dVth_dVb'
  assert block.count(old) == 2
  block=block.replace(old,'dDenomi_dVb = (dDenomi_dVg * 2.0 + 2.0 * pParam->BSIM4ud * Vth / (T3 * T3)) * dVth_dVb')
  block,count=re.subn(r'T7 = - 2.0 \* T6 / T0;\s*dDenomi_dVg = T2 \* dT1_dVg \+ T7;', 'T7 = -2.0 * T6 / (T0 * model->BSIM4toxe);\\n              dDenomi_dVg = T2 * dT1_dVg + T7;',block)
  assert count == 1
  block=block.replace('dDenomi_dVd = 0.0;', 'dDenomi_dVd = 2.0 * pParam->BSIM4ud * Vth / (T3 * T3) * dVth_dVd;')
  block=block.replace('dDenomi_dVb = T1 * pParam->BSIM4uc;', 'dDenomi_dVb = T1 * pParam->BSIM4uc + 2.0 * pParam->BSIM4ud * Vth / (T3 * T3) * dVth_dVb;')
  s=s[:start]+block+s[end:]
 if name == 'b4acld.c':
  s=s.replace('double capbd, capbs, omega;', 'double capbd, capbs, omega, nqsConductanceScale;')
  old='T0 = omega * here->BSIM4taunet;\n                  T1 = T0 * T0;\n                  T2 = 1.0 / (1.0 + T1);\n                  T3 = T0 * T2;'
  assert s.count(old)==1
  s=s.replace(old,'cs_bsim45_relaxation(omega, here->BSIM4taunet, &T2, &T3, &nqsConductanceScale);')
  s,count=re.subn(r'T3 \* omega', 'nqsConductanceScale', s)
  assert count==6
 s='/* Modified for CoreSpice: exclusive bounded preparation; see adapt_upstream.py and DESIGN.md. */\n'+s
 s='\n'.join(line.expandtabs(8).rstrip() for line in s.splitlines()).rstrip()+'\n'
 publish(target/name,s)
 manifest['files'][name]=dict(originalSHA256=hashlib.sha256(original).hexdigest(),adaptedSHA256=hashlib.sha256(s.encode()).hexdigest())
# Retain the original local spectrum and flicker law, excluding host sweep state.
noise=(source/'b4noi.c').read_text()
header=noise[:noise.index('\nint\nBSIM4noise')].replace('#include "fteconst.h"','')
header='#include "bsim4def.h"\n'+re.sub(r'^#include.*$', '', header, flags=re.M)
header=re.sub(r'extern (?:void\s+NevalSrc|double Nintegrate)\(\);', '', header)
header=header.replace('log(MAX(((N0 + here->BSIM4nstar) / (Nl + here->BSIM4nstar)), N_MINLOG))','log1p((N0-Nl)/(Nl+here->BSIM4nstar))')
header=header.replace('(N0 * N0 - Nl * Nl)','((N0-Nl)*(N0+Nl))')
start=noise.index('if (model->BSIM4tnoiMod == 0)',noise.index('case N_CALC:'))
end=noise.index('\n\t\t              *OnDens +=',start)
density=noise[start:end].replace('data->freq','frequency')
density=density.replace('pow(frequency, model->BSIM4ef)','1.0').replace('data->freq','1.0')
density,count=re.subn(r'(Eval1ovFNoise\(Vds, model, here,\s*)frequency',r'\g<1>1.0',density);assert count==1
pattern=r'NevalSrc\(&noizDens\[BSIM4FLNOIZ\], \(double\*\) NULL,.*?\(double\) 0.0\);'
density,count=re.subn(pattern,'noizDens[BSIM4FLNOIZ]=1.0;',density,flags=re.S);assert count==1
marker='lnNdens[BSIM4FLNOIZ] ='
assert density.count(marker)==1
old="""T1 = Swi + Ssi;
                                      if (T1 > 0.0)
                                          noizDens[BSIM4FLNOIZ] *= (Ssi * Swi) / T1;
                                      else
                                          noizDens[BSIM4FLNOIZ] *= 0.0;"""
assert density.count(old)==1
density=density.replace(old,"""if(!isfinite(Ssi)||!isfinite(Swi)||Ssi<0||Swi<0)return CS_BSIM45_NONFINITE;
                                      noizDens[BSIM4FLNOIZ] *= (Ssi==0||Swi==0)?0:fmin(Ssi,Swi)/(1+fmin(Ssi,Swi)/fmax(Ssi,Swi));""")
density=density.replace(marker,"""if(!isfinite(noizDens[BSIM4FLNOIZ])||noizDens[BSIM4FLNOIZ]<0)return CS_BSIM45_NONFINITE;
                              noizDens[BSIM4FLNOIZ]=cs_noise_project(&context,here->BSIM4dNodePrime,here->BSIM4sNodePrime,
                                  noizDens[BSIM4FLNOIZ]>0?log(noizDens[BSIM4FLNOIZ])-model->BSIM4ef*log(frequency):0,noizDens[BSIM4FLNOIZ]==0);
                              """+marker)
wrapper="""
#include "noise_primitives.inc"
int cs_bsim45_noise_density(BSIM4model *model,BSIM4instance *here,CKTcircuit *ckt,double frequency,
 const double *real,const double *imaginary,double noizDens[14]) {
 CSBSIM45NoiseContext context={real,imaginary,ckt,0};
 struct bsim4SizeDependParam *pParam=here->pParam;double lnNdens[14];
 double T0,T1,T2,T3,T4,T5,T6,T7,T8,T9,T10,T11,T12,T13,Vds,n,ExpArg,Ssi,Swi;
 double tmp,gdpr,gspr,npart_theta,npart_beta,igsquare,bodymode;
 if(model->BSIM4fnoiMod==1&&pParam->BSIM4leff-2*model->BSIM4lintnoi<=0)return CS_BSIM45_NONFINITE;
"""
ending="""
 if(context.failed)return CS_BSIM45_NONFINITE;
 for(int n=0;n<14;n++)if(!isfinite(noizDens[n])||noizDens[n]<0)return CS_BSIM45_NONFINITE;
 return CS_BSIM45_OK;
}
"""
text='/* Modified for CoreSpice: exact local noise with scoped transfer gains; no simulator sweep/history. */\n'+header+wrapper+density+ending
text='\n'.join(line.expandtabs(8).rstrip() for line in text.splitlines()).rstrip()+'\n'
publish(target/'b4noi.c',text)
manifest['files']['b4noi.c']=dict(originalSHA256=hashlib.sha256(noise.encode()).hexdigest(),adaptedSHA256=hashlib.sha256(text.encode()).hexdigest(),adaptation='Original local N_DENS and Eval1ovFNoise; scoped stable pair-gain projection, pinned SPICE3f5 constants; no traversal, nVar writes or simulator integration')
publish(target/'B4TERMS_OF_USE',(source/'B4TERMS_OF_USE').read_bytes())
publish(target/'upstream.json',json.dumps(manifest,indent=2)+'\n')

# Compile-time scalar checks cover all original owned doubles, including geometry
# key fields. Pointer fields and noise/history arrays are not scalar inputs.
definition = (target/'bsim4def.h').read_text()
finite = '/* Generated scalar finiteness checks for original owned physical fields. */\nstatic int prepared_finite(const CSBSIM45Owner *h) {\n'
for pattern, owner in [(r'typedef struct sBSIM4instance\s*\{(.*?)\}\s*BSIM4instance\s*;','instance'), (r'typedef struct sBSIM4model\s*\{(.*?)\}\s*BSIM4model\s*;','model'), (r'struct bsim4SizeDependParam\s*\{(.*?)\};','geometry')]:
    match = re.search(pattern, definition, re.S)
    assert match, owner
    for field in re.findall(r'\bdouble\s+(\w+)\s*;', match[1]):
        finite += f' if(!isfinite(h->{owner}.{field}))return 0;\n'
finite += ' return 1;\n}\n'
publish(target/'finite.inc',finite)
