"""Compile and execute the actual C ABI with bounded sanitizer/cold proofs."""
from pathlib import Path
import subprocess, tempfile, os
root=Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='corespice-bsim3-cold-') as temporary:
    temp=Path(temporary);binary=temp/'probe';cwd=temp/'readonly';cwd.mkdir();cwd.chmod(0o555)
    source=root/'Sources/CoreSpiceBSIM3'
    subprocess.run(['clang','-std=c17','-Wno-deprecated-non-prototype','-fsanitize=address,undefined',
        '-fno-omit-frame-pointer','-g','-I',str(source/'include'),'-I',str(source/'Kernel'),
        str(Path(__file__).with_name('cold_probe.c')), *map(str, sorted((source/'Kernel').glob('*.c'))),
        '-o',str(binary)], check=True, timeout=60)
    try:
        subprocess.run([str(binary)],cwd=cwd,check=True,timeout=30,
            env={**os.environ,'ASAN_OPTIONS':'detect_leaks=1:halt_on_error=1','UBSAN_OPTIONS':'halt_on_error=1'})
        assert not list(cwd.iterdir()), 'Kernel wrote an unexpected file'
    finally:cwd.chmod(0o755)
