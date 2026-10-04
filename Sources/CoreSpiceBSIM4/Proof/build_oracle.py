"""Link an isolated BSIM4-only registry against existing NG46 build artifacts."""
from pathlib import Path
import hashlib,json,subprocess,sys,time
root=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True)
source=(root/'src/spicelib/devices/dev.c').read_text();source=source.replace('get_bsim3_info, get_cap_info, get_res_info, get_vsrc_info','get_bsim4_info, get_cap_info, get_res_info, get_vsrc_info')
assert 'get_bsim4_info, get_cap_info' in source
(out/'dev.c').write_text(source)
start=time.monotonic()
cmd=['clang','-O0','-DHAVE_CONFIG_H','-I'+str(root/'src/include'),'-I'+str(root/'src/spicelib/devices'),'-c',str(out/'dev.c'),'-o',str(out/'dev.o')]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=30);(out/'registry-compile.log').write_text(r.stdout+r.stderr);r.check_returncode()
libraries=['frontend/libfte','frontend/plotting/libplotting','spicelib/devices/bsim4/libbsim4','spicelib/devices/cap/libcap','spicelib/devices/res/libres','spicelib/devices/vsrc/libvsrc','spicelib/analysis/libckt','spicelib/devices/libdev','frontend/parser/libparser','frontend/numparam/libnumparam','frontend/trannoise/libtrannoise','spicelib/parser/libinp','osdi/libosdi','maths/deriv/libderiv','maths/cmaths/libcmaths','maths/misc/libmathmisc','maths/fft/libmathfft','maths/poly/libpoly','maths/ni/libni','maths/KLU/libKLU','maths/sparse/libsparse','misc/libmisc','maths/dense/libdense']
archives=[root/'src'/Path(x).parent/'.libs'/(Path(x).name+'.a')for x in libraries]
cmd=['clang',*[str(root/'src'/n)for n in ['ngspice-main.o','ngspice-conf.o','ngspice-ngspice.o']],str(out/'dev.o'),*map(str,archives),'-lm','-lc++','-o',str(out/'ngspice-bsim4')]
r=subprocess.run(cmd,capture_output=True,text=True,timeout=30);(out/'link.log').write_text(r.stdout+r.stderr);r.check_returncode()
hashfile=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest={'ngspiceSourceTag':'ngspice-46','ngspiceCommit':'ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6','elapsedSeconds':time.monotonic()-start,'registrySHA256':hashfile(out/'dev.c'),'executableSHA256':hashfile(out/'ngspice-bsim4'),'archives':{str(p.relative_to(root)):hashfile(p)for p in archives},'hostConstantsSHA256':hashfile(root/'src/include/ngspice/const.h'),'bsim4Sources':{p.name:hashfile(p)for p in (root/'src/spicelib/devices/bsim4').glob('*.c')}}
(out/'oracle-provenance.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps({'seconds':manifest['elapsedSeconds'],'binary':str(out/'ngspice-bsim4')}))
