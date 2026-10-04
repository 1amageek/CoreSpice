"""Reproduce simulator isolation of Berkeley Standard BSIM4 4.8.3."""
from pathlib import Path
import hashlib,json,re,sys
source=Path(sys.argv[1]);target=Path(__file__).resolve().parent
files=['b4.c','b4mpar.c','b4par.c','b4set.c','b4temp.c','b4check.c','b4geo.c','b4ld.c','b4acld.c','bsim4def.h','bsim4ext.h']
geometry=['BSIM4NumFingerDiff','BSIM4PAeffGeo','BSIM4RdseffGeo','BSIM4RdsEndIso','BSIM4RdsEndSha']
manifest={'release':'4.8.3','archiveURL':'https://www.bsim.berkeley.edu/wp-content/uploads/BSIM4/BSIM4_4.8.3_standard_05192025.tar','archiveSHA256':'3e3bb0ccb0699cb50d3844b6a2f6ee00f3ec6e1149e3ce4867cf47f5b27b56f7','files':{}}
for name in files:
 original=(source/name).read_bytes();s=original.decode()
 if name=='b4.c':
  s=s[:s.index('char *BSIM4names')].replace('IFparm BSIM4','const IFparm BSIM4')
  s+='\nconst int BSIM4pTSize=NUMELEMS(BSIM4pTable);\nconst int BSIM4mPTSize=NUMELEMS(BSIM4mPTable);\n'
 if name=='b4set.c':
  start=s.index('JOB   *job;');end=s.index('    /*  loop through all',start)
  s=s[:start]+'noiseAnalGiven = ckt->noiseRequested;\n\n'+s[end:]
 if name=='b4check.c':
  # Most console messages duplicate the file diagnostic. Retain the mode-1
  # console-only warning as a structured diagnostic with its original condition.
  warning='printf("Warning: TNOIMOD=1 is not supported and may be removed from future version.\\n", model->BSIM4tnoiMod);'
  assert s.count(warning)==1
  s=s.replace(warning,'cs_diagnostic(ckt,"Warning: TNOIMOD=1 is not supported and may be removed from future version.\\n");')
  s=s.replace('FILE *fplog;','').replace('if ((fplog = fopen("bsim4.out", "w")) != NULL)','/* All checks execute independently of filesystem availability. */')
  s=re.sub(r'\bprintf\((?:"(?:[^"\\]|\\.)*"|[^";])*\);',';',s)
  s=s.replace('fprintf(fplog,','cs_diagnostic(ckt,').replace('fclose(fplog);','')
  start=s.index('    else\n    {   fprintf(stderr, "Warning: Can');end=s.index('    return(Fatal_Flag);',start)
  s=s[:start]+s[end:]
 if name=='b4temp.c':
  # Negative-phi diagnostics originally use an uninitialized FILE pointer.
  # Their duplicate console message and original fatal check remain below.
  s=s.replace('FILE *fplog;','')
  s=re.sub(r'fprintf\(fplog,(?:"(?:[^"\\]|\\.)*"|[^";])*\);',';',s)
 if name in ['b4set.c','b4temp.c','b4geo.c']:
  s=re.sub(r'fprintf\((?:stderr|stdout),','cs_diagnostic(ckt,',s)
  s=re.sub(r'\bprintf\s*\(','cs_diagnostic(ckt,',s)
  s=re.sub(r'\(\*\(SPfrontEnd->IFerror\)\)\s*\(ERR_FATAL,','cs_fatal(ckt,',s)
  s=s.replace('malloc(','cs_allocate_size(ckt,')
  for function in geometry:
   s=re.sub(r'\b'+function+r'\((?!\))',function+'(ckt, ',s)
  if name=='b4geo.c':
   for function in geometry:
    pat=r'('+function+r'\(ckt, [^)]*\)\n)'
    s,count=re.subn(pat,r'\1CKTcircuit *ckt;\n',s)
    assert count==1,(function,count)
 if name=='b4ld.c':
  # Preserve independently scaled current I and charge Q laws. Original
  # body RHS and physical NQS q couplings omitted the charge multiplier.
  corrections={
   'mult_i * (ceqjd + ceqqjd)': 'mult_i * ceqjd + mult_q * ceqqjd',
   'mult_i * (ceqjs + ceqqjs)': 'mult_i * ceqjs + mult_q * ceqqjs',
   '(*(here->BSIM4DPqPtr) += dxpart * here->BSIM4gtau)': '(*(here->BSIM4DPqPtr) += mult_q * dxpart * here->BSIM4gtau)',
   '(*(here->BSIM4SPqPtr) += sxpart * here->BSIM4gtau)': '(*(here->BSIM4SPqPtr) += mult_q * sxpart * here->BSIM4gtau)',
   '(*(here->BSIM4GPqPtr) -= here->BSIM4gtau)': '(*(here->BSIM4GPqPtr) -= mult_q * here->BSIM4gtau)'
  }
  for before,after in corrections.items():
   assert s.count(before)==1,(name,before,s.count(before))
   s=s.replace(before,after)
  manifest['chargeMultiplicityCorrection']={
   'source':'b4ld.c','reason':'Current law mult_i*I and charge law mult_q*Q require matching equivalent RHS and analytic derivatives; original body and physical NQS couplings violate this when factors differ.',
   'expressions':[{'original':before,'corrected':after}for before,after in corrections.items()],
   'independentCorrectedImplementation':'ngspice-46 b4ld.c SHA256 cdff60297be2153763cdea198a0edda17c60d6cc659a78024b3e1c9eb0a91672'
  }
  s='/* Modified for CoreSpice: correct body/NQS charge multiplicity; Kernel/DESIGN.md owns the derivation. */\n'+s
  s=s.replace('DEVfetlim(','cs_exact_fet_bias(').replace('DEVlimvds(','cs_exact_drain_bias(').replace('DEVpnjlim(','cs_exact_junction_bias(')
 s='/* Modified for CoreSpice: context-local simulator isolation; see adapt_upstream.py. */\n'+s
 s='\n'.join(line.expandtabs(8).rstrip()for line in s.splitlines()).rstrip()+'\n'
 (target/name).write_text(s)
 manifest['files'][name]={'originalSHA256':hashlib.sha256(original).hexdigest(),'adaptedSHA256':hashlib.sha256(s.encode()).hexdigest()}


# Extract the exact local spectrum, excluding simulator traversal/integration.
noise=(source/'b4noi.c').read_text()
strong=noise[noise.index('double\nEval1ovFNoise'):noise.index('\nint\nBSIM4noise')]
strong=strong.replace('double\nEval1ovFNoise', 'static double\nEval1ovFNoise')
start=noise.index('if (model->BSIM4tnoiMod == 0)')
end=noise.index('noizDens[BSIM4TOTNOIZ] =',start)
density=noise[start:end].replace('data->freq','frequency')
# Reject invalid intermediate values before original conditional/clamp branches.
density=density.replace('T1 = Swi + Ssi;', 'T1 = Swi + Ssi;\n if (!isfinite(Ssi) || !isfinite(Swi) || !isfinite(T1)) return CS_BSIM4_NUMERICAL;')
density=density.replace('T9 = gamma * delta ;', 'T9 = gamma * delta ;\n if (!isfinite(gamma) || !isfinite(delta) || !isfinite(epsilon) || !isfinite(T9)) return CS_BSIM4_NUMERICAL;')
header=noise[:noise.index('#include "spice.h"')]
wrapper=(target/'noise_primitives.inc').read_text()
entry="""
int cs_bsim4_noise_density(BSIM4model *model, BSIM4instance *here,
 CKTcircuit *ckt, double frequency, const double real[13], const double imag[13], double noizDens[14]) {
 struct bsim4SizeDependParam *pParam=here->pParam;
 CSBSIM4NoiseContext context={ckt,real,imag,0};
 double lnNdens[14];
 double T0,T1,T2,T3,T4,T5,T6,T7,T8,T9,T10,T11,T12,T13;
 double Vds,n,ExpArg,Ssi,Swi,tmp,gdpr,gspr,npart_theta,npart_beta,igsquare,bodymode;
 double eta,Leff,Lvsat,gamma,delta,epsilon,GammaGd0,npart_c,sigrat,C0,omega,ctnoi,tau;
 double mult_i=here->BSIM4mult_i,mult_fn=here->BSIM4mult_fn;
 double frequencyPower=pow(frequency,model->BSIM4ef);
 if (!isfinite(frequencyPower) || frequencyPower<=0 || (model->BSIM4fnoiMod==1 && pParam->BSIM4leff-2*model->BSIM4lintnoi<=0)) return CS_BSIM4_NUMERICAL;
"""
ending="""
 if(context.failed) return CS_BSIM4_NUMERICAL;
 for(int index=0;index<14;index++) if(!isfinite(noizDens[index])||noizDens[index]<0) return CS_BSIM4_NUMERICAL;
 return CS_BSIM4_OK;
}
"""
spectrum='/* Modified for CoreSpice: local original spectrum and scoped complex transfer primitive; no simulator noise history. */\n'+header+'\n'+wrapper+'\n'+strong+'\n'+entry+density+ending
spectrum='\n'.join(line.expandtabs(8).rstrip()for line in spectrum.splitlines()).rstrip()+'\n'
(target/'b4noi.c').write_text(spectrum)
manifest['noisePrimitiveProvenance']={'source':'ngspice-46 src/spicelib/analysis/nevalsrc.c','sourceSHA256':'ce85b15a7f30479f51d4f9bf38c7c581a0949dee3613bbd59a806c59930398cc','license':'Modified BSD, retained in NOISE_PRIMITIVE_LICENSE','modifiedPrimitiveSHA256':hashlib.sha256(wrapper.encode()).hexdigest()}
manifest['files']['b4noi.c']={'originalSHA256':hashlib.sha256(noise.encode()).hexdigest(),'adaptedSHA256':hashlib.sha256(spectrum.encode()).hexdigest(),'adaptation':'Exact local N_DENS and Eval1ovFNoise; scoped full-node complex gain primitives, SI2019 host constants, numerical guards; simulator traversal and integration excluded.'}
(target/'upstream.json').write_text(json.dumps(manifest,indent=2)+'\n')
