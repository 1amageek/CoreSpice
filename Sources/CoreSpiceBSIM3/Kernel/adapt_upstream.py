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
