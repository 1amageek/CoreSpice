from pathlib import Path
import re
import sys
src=Path(sys.argv[1]); out=Path(__file__).resolve().parent
for name in ['b3.c','b3set.c','b3temp.c','b3check.c','b3ld.c','b3acld.c','b3mpar.c','b3par.c','bsim3def.h','bsim3ext.h']:
 s=(src/name).read_text();s=re.sub(r'static char rcsid\[\]','static const char rcsid[]',s)
 if name=='b3.c':s=s[:s.index('char *BSIM3names')].replace('IFparm BSIM3','const IFparm BSIM3')
 if name=='b3check.c':
  s=s.replace('FILE *fplog;','').replace('if ((fplog = fopen("b3v3check.log", "w")) != NULL)','/* Checking is independent of filesystem availability. */')
  s=re.sub(r'\bprintf\((?:"(?:[^"\\]|\\.)*"|[^";])*\);' ,'',s).replace('fprintf(fplog,','cs_diagnostic(ckt,').replace('fclose(fplog);','')
  start=s.index('    else\n    {   fprintf(stderr, "Warning: Can')
  end=s.index('    return(Fatal_Flag);',start)
  s=s[:start]+s[end:]
 if name in ['b3temp.c','b3set.c']:
  s=re.sub(r'fprintf\((?:stderr|stdout),','cs_diagnostic(ckt,',s);s=re.sub(r'\bprintf\(','cs_diagnostic(ckt,',s)
  s=re.sub(r'\(\*\(SPfrontEnd->IFerror\)\)\s*\(ERR_FATAL,','cs_fatal(ckt,',s).replace('malloc(','cs_allocate_size(ckt,')
 if name=='b3ld.c':s=s.replace('if (FABS(cbhat - Ibtot)) > tol)', 'if (FABS(cbhat - Ibtot) > tol)');s=s.replace('DEVfetlim(','cs_exact_fet_bias(').replace('DEVlimvds(','cs_exact_drain_bias(').replace('DEVpnjlim(','cs_exact_junction_bias(')
 if name=='b3ld.c':
  old='dT0_dVb * (1.0 - T5) + T5 * dT1_dVb'
  assert s.count(old)==1
  s=s.replace(old, 'dT0_dVb * (T4 - T5) + T5 * dT1_dVb')
 if name=='b3.c':s+='\nconst int BSIM3pTSize = NUMELEMS(BSIM3pTable);\nconst int BSIM3mPTSize = NUMELEMS(BSIM3mPTable);\n'
 (out/name).write_text('\n'.join(re.sub(r'^[ \t]+', lambda match: match.group().expandtabs(8), line.rstrip()) for line in s.splitlines()).rstrip()+'\n')

# Extract only the original local N_DENS equations, not SPICE3 traversal,
# frontend registration, total-source duplication or noise integration history.
noise = (src / 'b3noi.c').read_text()
strong = noise[noise.index('double\nStrongInversionNoiseEval'):noise.index('\nint\nBSIM3noise')]
strong = strong.replace('double\nStrongInversionNoiseEval(Vds, model, here, freq, temp)\ndouble Vds, freq, temp;\nBSIM3model *model;\nBSIM3instance *here;',
    'static double StrongInversionNoiseEval(double Vds, BSIM3model *model, BSIM3instance *here, double freq, double temp)')
start = noise.index('NevalSrc(&noizDens[BSIM3RDNOIZ]')
end = noise.index('lnNdens[BSIM3FLNOIZ] =', start)
density = noise[start:end].replace('ckt->CKTstates[0]', 'ckt->CKTstate0').replace('data->freq', 'frequency')
density = density.replace('T1 = Swi + Ssi;', 'T1 = Swi + Ssi;\n    if (!isfinite(Ssi) || !isfinite(Swi) || !isfinite(T1)) return CS_BSIM3_NUMERICAL;')
preamble = noise[:noise.index('static char rcsid')]
wrapper = """
#include "bsim3def.h"
#include "../include/CoreSpiceBSIM3.h"
#define CHARGE 1.602176634e-19
#define N_MINLOG 1e-38
#define MIN(a,b) ((a)<(b)?(a):(b))
#define THERMNOISE 1
#define N_GAIN 2
/* Current PSD only. The analysis owns the transfer function and integration. */
static void NevalSrc(double *density, double *logDensity, CKTcircuit *ckt,
                     int type, int positive, int negative, double conductance) {
    *density = type == THERMNOISE ? 4 * 1.380649e-23 * ckt->CKTtemp * conductance : 1;
    if (logDensity) *logDensity = log(MAX(*density, N_MINLOG));
}
"""
entry = """
int cs_bsim3_noise_density(BSIM3model *model, BSIM3instance *here,
                          CKTcircuit *ckt, double frequency, double noizDens[4]) {
    struct bsim3SizeDependParam *pParam = here->pParam;
    double lnNdens[4], vds, Ssi, Swi, T1, T10, T11;
    double frequencyPower = pow(frequency, model->BSIM3ef);
    if (!isfinite(frequencyPower) || frequencyPower <= 0) return CS_BSIM3_NUMERICAL;
    if (model->BSIM3noiMod < 1 || model->BSIM3noiMod > 6) return E_BADPARM;
    if ((model->BSIM3noiMod == 2 || model->BSIM3noiMod == 3 || model->BSIM3noiMod == 6)
        && pParam->BSIM3leff - 2 * model->BSIM3lintnoi <= 0) return E_BADPARM;
"""
ending = """
    return OK;
}
"""
result = preamble + wrapper + strong + entry + density + ending
(out / 'b3noi.c').write_text('\n'.join(line.expandtabs(8).rstrip() for line in result.splitlines()).rstrip() + '\n')
