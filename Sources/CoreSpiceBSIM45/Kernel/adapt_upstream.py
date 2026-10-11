"""Reproduce the preparation-only isolation of the official nested BSIM4 4.5.0."""
from pathlib import Path
import hashlib, json, re, sys
source = Path(sys.argv[1]); target = Path(__file__).resolve().parent
check = '--check' in sys.argv[2:]
def publish(path, data):
 if isinstance(data,str): data=data.encode()
 if check: assert path.read_bytes()==data,path
 else: path.write_bytes(data)
files = ['b4.c','b4mpar.c','b4par.c','b4set.c','b4temp.c','b4check.c','b4geo.c','bsim4def.h','bsim4ext.h']
geometry = ['BSIM4NumFingerDiff','BSIM4PAeffGeo','BSIM4RdseffGeo','BSIM4RdsEndIso','BSIM4RdsEndSha']
manifest = dict(release='4.5.0', adaptation='prepare-v1.sc-selector-v1.spice3f5-constants',
 archiveURL='https://www.bsim.berkeley.edu/BSIM4/BSIM450.zip',
 archiveSHA256='2d0bc2496bf9b9c18dd2f790c679bfa76426fcac4a1691688fcb6a80a590f3e8',
 nestedSHA256='d94a1df9367d565787f555cc8ce6bd515a34f4d1752fb1da91df6ab54c56e39f',
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
 s='/* Modified for CoreSpice: exclusive bounded preparation; see adapt_upstream.py and DESIGN.md. */\n'+s
 s='\n'.join(line.expandtabs(8).rstrip() for line in s.splitlines()).rstrip()+'\n'
 publish(target/name,s)
 manifest['files'][name]=dict(originalSHA256=hashlib.sha256(original).hexdigest(),adaptedSHA256=hashlib.sha256(s.encode()).hexdigest())
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
