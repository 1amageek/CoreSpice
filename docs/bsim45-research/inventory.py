from pathlib import Path
from collections import Counter,defaultdict
import re,json,hashlib,argparse
parser=argparse.ArgumentParser(description='Inventory original Sky130 declarations and Berkeley input tables; this does not execute SPICE.')
parser.add_argument('--originals',required=True,type=Path)
parser.add_argument('--pdk',required=True,type=Path)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args()
root=args.originals
pdk=args.pdk
args.output.mkdir(parents=True,exist_ok=True)
def assignments(s):
    starts=[];stack=[];quote=None;i=0
    while i<len(s):
        c=s[i]
        if quote:
            if c==quote:quote=None
        elif c in "\"'":quote=c
        elif c in '({':stack.append(c)
        elif c in ')}':
            assert stack and (stack.pop(),c) in [('(',')'),('{','}')],s
        elif not stack and (i==0 or s[i-1].isspace()):
            m=re.match(r'([A-Za-z_][\w]*)\s*=\s*',s[i:])
            if m:starts.append((i,i+len(m[0]),m[1].lower()));i+=len(m[0])-1
        i+=1
    assert not stack and not quote,s
    out={}
    for n,(a,b,k) in enumerate(starts):
        assert k not in out,('duplicate',k,s)
        out[k]=s[b:starts[n+1][0] if n+1<len(starts) else len(s)].strip()
    return out
selectors='level version binunit mobmod capmod igcmod igbmod geomod rgeomod diomod rdsmod rbodymod rgatemod permod acnqsmod trnqsmod fnoimod tnoimod tempmod wpemod'.split()
files={};cards=[];wrappers=[];keys=Counter();values={k:Counter() for k in selectors};groups=defaultdict(lambda:{'cards':0,'files':set(),'parameters':set(),'selectors':{k:set()for k in selectors}})
for p in sorted(pdk.glob('*.spice')):
    data=p.read_bytes();files[p.name]={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    stmts=[];scope=[]
    for line,text in enumerate(data.decode().splitlines(),1):
        s=text.strip()
        if not s or s.startswith('*'):continue
        if s.startswith('+'):
            assert stmts,(p,line)
            stmts[-1][1]+=' '+s[1:].strip()
        else:stmts.append([line,s])
    for line,s in stmts:
        lower=s.lower()
        if lower.startswith('.subckt '):scope.append(s.split()[1])
        elif lower.startswith('.ends'):
            if scope:scope.pop()
        elif lower.startswith('.model '):
            m=re.match(r'\.model\s+(\S+)\s+(\w+)\s*(.*)',s,re.I);assert m,(p,line)
            if m[2].lower() not in ('nmos','pmos'):continue
            params=assignments(m[3]);level=params.get('level')
            if not level or float(level)!=54:continue
            family=re.sub(r'\.\d+$','',m[1].lower());group=groups[family]
            group['cards']+=1;group['files'].add(p.name);group['parameters'].update(params)
            for k in selectors:
                v=params.get(k,'<omitted>');values[k][v]+=1;group['selectors'][k].add(v)
            keys.update(params.keys())
            cards.append({'file':p.name,'line':line,'scope':list(scope),'name':m[1],'polarity':m[2].lower(),'parameters':params})
        elif lower.startswith('m') and scope:
            tokens=s.split();wrappers.append({'file':p.name,'line':line,'scope':list(scope),'instance':tokens[0],'model':tokens[5] if len(tokens)>5 else None,'parameters':assignments(s)})
assert cards
# Parameter tables are parsed only from input macros, not output-only records.
def table(path):
    text=path.read_text();parts=text.split('IFparm BSIM4mPTable[]');assert len(parts)==2
    def parse(x):return {m[1]:{'selector':m[2],'kind':m[3]}for m in re.finditer(r'\b(?:IOP|IP|IOPR)\s*\(\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(\w+)',x)}
    return {'instance':parse(parts[0]),'model':parse(parts[1])}
t45=table(root/'450-code/b4.c');t83=table(root/'483/code/b4.c')
diffs={}
for role in ('model','instance'):
    a,b=t45[role],t83[role]
    diffs[role]={'count45':len(a),'count483':len(b),'added483':sorted(b.keys()-a.keys()),'removed483':sorted(a.keys()-b.keys()),'changed':{k:{'45':a[k],'483':b[k]}for k in a.keys()&b.keys()if a[k]!=b[k]}}
for g in groups.values():
    g['files']=sorted(g['files']);g['parameters']=sorted(g['parameters']);g['selectors']={k:sorted(v)for k,v in g['selectors'].items()}
missing=sorted(keys.keys()-t45['model'].keys()-{'level','lmin','lmax','wmin','wmax'})
report={'root':str(pdk),'fileCount':len(files),'bytes':sum(x['bytes']for x in files.values()),'files':files,'level54CardOccurrences':len(cards),'bsim45CardOccurrences':sum(x['parameters']['version'] in ('4.5','4.500000e+0') for x in cards),'familyCount':len(groups),'families':dict(sorted(groups.items())),'parameterOccurrences':dict(sorted(keys.items())),'selectors':{k:dict(v)for k,v in values.items()},'modelParametersOutsideOriginal45':missing,'mosWrapperCount':len(wrappers),'mosWrapperParameterNames':sorted({k for w in wrappers for k in w['parameters']}),'sourceTableDifferences':diffs,'originalTables':{'45':t45,'483':t83}}
(args.output/'inventory.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
(args.output/'cards.json').write_text(json.dumps(cards,indent=2)+'\n')
(args.output/'wrappers.json').write_text(json.dumps(wrappers,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items()if k in ('fileCount','bytes','bsim45CardOccurrences','familyCount','selectors','modelParametersOutsideOriginal45','mosWrapperCount','mosWrapperParameterNames','sourceTableDifferences')},indent=2))
