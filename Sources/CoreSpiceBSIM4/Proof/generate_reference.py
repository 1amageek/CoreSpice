"""Pin independent NG46 OP scalars and internal-node biases for original physics."""
import ctypes as C,hashlib,json,math,subprocess,sys,time
from pathlib import Path
import numpy as np
native=Path(sys.argv[1]);oracle=Path(sys.argv[2]);out=Path(sys.argv[3]);out.mkdir(parents=True,exist_ok=True)
class Topology(C.Structure):_fields_=[(n,C.c_int)for n in ['nodeCount','drainPrime','sourcePrime','gatePrime','gateMid','bodyPrime','drainBody','sourceBody','chargeNode','noiseRequested','maintainerUnsupportedNoiseMode']]
class Result(C.Structure):_fields_=[(n,C.c_double*k)for n,k in [('residual',13),('rhs',13),('charge',13),('real',169),('imaginary',169),('states',29),('operatingPoint',8),('intrinsicCharges',4)]]+[('token',C.c_uint64)]
lib=C.CDLL(str(native));ptr=C.c_void_p
lib.cs_bsim4_create.argtypes=[C.c_int,C.c_char_p,C.c_double,C.c_int,C.POINTER(ptr)];lib.cs_bsim4_parameter.argtypes=[ptr,C.c_int,C.c_char_p,C.c_double];lib.cs_bsim4_prepare.argtypes=[ptr,C.POINTER(Topology)];lib.cs_bsim4_evaluate.argtypes=[ptr,C.POINTER(C.c_double),C.c_int,C.c_double,C.c_double,C.c_double,C.POINTER(Result)];lib.cs_bsim4_destroy.argtypes=[ptr];lib.cs_bsim4_set_stress_budget.argtypes=[ptr,C.c_uint32]
roles=['drainPrime','sourcePrime','gatePrime','gateMid','bodyPrime','drainBody','sourceBody','chargeNode'];suffixes=['drain','source','gate','midgate','body','dbody','sbody','charge']
cases=[]
for polarity in [1,-1]:
 for name,d,g,b,temp in [('linear',.2,1.2,0,300.15),('saturation',1,1.2,0,300.15),('cutoff',1,.2,-.2,300.15),('reverse',-.3,.9,.12,300.15),('hot',1,1.2,0,350.15)]:cases.append((f'{polarity}_{name}',polarity,d,g,b,temp,{},{}))
 for kind in ['series','bodygate','nqs','fingers','multipliers','stress']:
  mp={'rsh':20}if kind in ['series','bodygate','nqs']else{}
  ip={'nrd':1,'nrs':1}if mp else{}
  if kind in ['bodygate','nqs']:ip.update(rbodymod=1,rgatemod=3,ad=1e-12,**{'as':1e-12},pd=4e-6,ps=4e-6);mp.update(cgso=1e-10,cgdo=1e-10,cgbo=1e-10)
  if kind=='nqs':ip.update(trnqsmod=1,acnqsmod=1)
  if kind=='stress':ip.update(nf=1.5,sa=1e-6,sb=1e-6,sd=1e-6)
  if kind=='fingers':ip['nf']=2
  if kind=='multipliers':ip.update(mult_i=1.3,mult_q=.8,mult_fn=1.5)
  cases.append((f'{polarity}_{kind}',polarity,1,1.2,0,300.15,mp,ip))
records=[];started=time.monotonic()
for name,p,d,g,b,temp,mp,ip in cases:
 model={'vth0':p*.7,'u0':.05,'toxe':1e-8,**mp};inst={'l':1e-6,'w':1e-5,**ip};h=ptr();assert lib.cs_bsim4_create(p,b'4.8.3',temp,1,C.byref(h))==0
 try:
  assert lib.cs_bsim4_set_stress_budget(h,8)==0
  for scope,params in [(1,model),(0,inst)]:
   for key,value in params.items():assert lib.cs_bsim4_parameter(h,scope,key.encode(),value)==0
  t=Topology();assert lib.cs_bsim4_prepare(h,C.byref(t))==0
  nodeQueries=['v(d)','v(g)','v(s)','v(b)'];queryRoles=[]
  for role,suffix in zip(roles,suffixes):
   index=getattr(t,role)
   if index>4 and index not in [x[1]for x in queryRoles]:nodeQueries.append(f'v(m1#{suffix})');queryRoles.append((role,index))
  ops=['id','gm','gds','gmbs','vth','vdsat','isub'];charges=['qg','qd','qb','qs']
  queries=nodeQueries+[f'@m1[{n}]'for n in ops+charges]
  deck=f'Independent BSIM4 {name}\n.temp {temp-273.15:.17g}\n.model ch {"nmos"if p==1 else "pmos"} level=54 version=4.8.3 '+' '.join(f'{k}={v:.17g}'for k,v in model.items())+'\n'+f'VD d 0 {p*d:.17g}\nVG g 0 {p*g:.17g}\nVS s 0 0\nVB b 0 {p*b:.17g}\nM1 d g s b ch '+' '.join(f'{k}={v:.17g}'for k,v in inst.items())+f'\n.control\nset noaskquit\nset numdgt=15\nset wr_singlescale\nset wr_vecnames\nsave {(' '.join(nodeQueries))}\nop\nwrdata {out/name}.dat '+' '.join(queries)+'\nquit\n.endc\n.end\n'
  path=out/(name+'.cir');path.write_text(deck);run=subprocess.run([str(oracle),'-b',str(path)],cwd=out,capture_output=True,text=True,timeout=10);(out/(name+'.log')).write_text(run.stdout+run.stderr);run.check_returncode()
  lines=(out/(name+'.dat')).read_text().splitlines();values=list(map(float,lines[-1].split()))[1:];assert len(values)==len(queries),(name,len(values),queries)
  bias=[0.]*13;bias[1:5]=values[:4]
  for offset,(_,index) in enumerate(queryRoles,4):bias[index]=values[offset]
  point=Result();status=lib.cs_bsim4_evaluate(h,(C.c_double*13)(*bias),0,0,0,0,C.byref(point));assert status==0,(name,status)
  scalar=values[len(nodeQueries):len(nodeQueries)+7];nativePoint=list(point.operatingPoint)[:7]
  for i,(actual,expected)in enumerate(zip(nativePoint,scalar)):
   assert abs(actual-expected)<=1e-13+2e-7*max(abs(actual),abs(expected)),(name,ops[i],actual,expected)
  for actual,expected in zip(point.intrinsicCharges,values[-4:]):assert abs(actual-expected)<=1e-23+2e-7*max(abs(actual),abs(expected)),(name,'intrinsic charge',actual,expected)
  acRecords=[]
  if name.split('_',1)[1] in ['saturation','series','bodygate','nqs']:
   for frequency in [1e3,1e8,1e11]:
    acpath=out/f'{name}_ac_{frequency:g}.dat'
    acdeck=deck.replace(f'VG g 0 {p*g:.17g}',f'VG g 0 {p*g:.17g} AC 1').replace('\nquit\n',f'\nac lin 1 {frequency:g} {frequency:g}\nwrdata {acpath} vd#branch vg#branch\nquit\n')
    acdeck=acdeck.replace('\nop\n',' vd#branch vg#branch\nop\n')
    acfile=out/f'{name}_ac_{frequency:g}.cir';acfile.write_text(acdeck)
    acRun=subprocess.run([str(oracle),'-b',str(acfile)],cwd=out,capture_output=True,text=True,timeout=10);(acfile.with_suffix('.log')).write_text(acRun.stdout+acRun.stderr);acRun.check_returncode()
    acvalues=list(map(float,acpath.read_text().splitlines()[-1].split()))[1:];assert len(acvalues)==4,(name,acvalues)
    response=Result();assert lib.cs_bsim4_evaluate(h,(C.c_double*13)(*bias),1,2*math.pi*frequency,0,0,C.byref(response))==0
    matrix=np.array(response.real).reshape(13,13)+1j*np.array(response.imaginary).reshape(13,13)
    # Original AC load has no explicit transient q-deficit row. Preserve the
    # topology role at zero; only physical internal nodes are AC unknowns.
    unknown=[n for n in range(5,t.nodeCount+1)if n!=t.chargeNode]
    voltage=np.zeros(13,dtype=complex);voltage[2]=1
    if unknown:voltage[unknown]=np.linalg.solve(matrix[np.ix_(unknown,unknown)],-matrix[unknown,2])
    branches=-(matrix@voltage)[[1,2]]
    expected=np.array([complex(*acvalues[:2]),complex(*acvalues[2:])])
    assert np.all(np.abs(branches-expected)<=1e-13+2e-7*np.maximum(np.abs(branches),np.abs(expected))),(name,frequency,branches,expected)
    acRecords.append({'frequencyHz':frequency,'branchCurrents':acvalues,'deckSHA256':hashlib.sha256(acdeck.encode()).hexdigest(),'rawSHA256':hashlib.sha256(acpath.read_bytes()).hexdigest()})
  records.append({'ac':acRecords,'name':name,'polarity':p,'temperature':temp,'modelParameters':model,'instanceParameters':inst,'bias':bias,'operatingPoint':scalar,'intrinsicCharges':values[-4:],'nativePoint':nativePoint,'deckSHA256':hashlib.sha256(deck.encode()).hexdigest(),'rawSHA256':hashlib.sha256((out/(name+'.dat')).read_bytes()).hexdigest()})
 finally:lib.cs_bsim4_destroy(h)
print('PASS reference cases',len(records),'AC points',sum(len(r['ac'])for r in records),'seconds',time.monotonic()-started)
(out/'reference.json').write_text(json.dumps({'release':'4.8.3','oracleExecutableSHA256':hashlib.sha256(oracle.read_bytes()).hexdigest(),'cases':records},indent=2)+'\n')
