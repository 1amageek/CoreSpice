"""Build the independent reference outside the production package graph."""
from pathlib import Path
import argparse, hashlib, os, re, signal, subprocess, tarfile

parser = argparse.ArgumentParser()
parser.add_argument('archive', type=Path)
parser.add_argument('destination', type=Path)
arguments = parser.parse_args()
assert hashlib.sha256(arguments.archive.read_bytes()).hexdigest() == 'a0d1699af1940b06649276dcd6ff5a566c8c0cad01b2f7b5e99dedbb4d64c19b'
arguments.destination.mkdir(parents=True, exist_ok=True)
with tarfile.open(arguments.archive) as archive:
    archive.extractall(arguments.destination, filter='data')
source = arguments.destination / 'ngspice-46'
load = source / 'src/spicelib/devices/bsim3/b3ld.c'
assert hashlib.sha256(load.read_bytes()).hexdigest() == '65c608a7760a902d59eb9764841a291176b9a3b4fb81dce923dc08462f28f65c'
text = load.read_text()
old = 'dVdseffCV_dVb = dT0_dVb * (1.0 - T5) + T5 * dT1_dVb;'
assert text.count(old) == 1
load.write_text(text.replace(old, 'dVdseffCV_dVb = dT0_dVb * (T4 - T5) + T5 * dT1_dVb;'))
registry = source / 'src/spicelib/devices/dev.c'
text, count = re.subn(r'static SPICEdev \*\(\*static_devices\[\]\)\(void\) = \{.*?\n\};',
    'static SPICEdev *(*static_devices[])(void) = {\n    get_bsim3_info, get_cap_info, get_res_info, get_vsrc_info\n};',
    registry.read_text(), flags=re.S)
assert count == 1
registry.write_text(text)

def execute(command, timeout, name):
    with (arguments.destination / name).open('w') as log:
        process = subprocess.Popen(command, cwd=source, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        if code:
            raise RuntimeError(f'{command} failed: {code}; see {name}')

# Dependency-file generation is unnecessary for this one-shot reference build.
execute(['./configure', '--without-x', '--with-readline=no', '--disable-openmp',
    '--disable-xspice', '--disable-cider', '--disable-dependency-tracking'], 120, 'configure.log')
makefile = source / 'src/spicelib/devices/Makefile'
text, count = re.subn(r'^SUBDIRS = .*?(?=\nDIST_SUBDIRS)', 'SUBDIRS = bsim3 cap res vsrc',
    makefile.read_text(), flags=re.S | re.M)
assert count == 1
makefile.write_text(text)
makefile = source / 'src/Makefile'
text, count = re.subn(r'^DYNAMIC_DEVICELIBS = .*?(?=\n\nngspice_SOURCES)',
    'DYNAMIC_DEVICELIBS = spicelib/devices/bsim3/libbsim3.la spicelib/devices/cap/libcap.la spicelib/devices/res/libres.la spicelib/devices/vsrc/libvsrc.la',
    makefile.read_text(), flags=re.S | re.M)
assert count == 1
makefile.write_text(text)
execute(['make', '-j6'], 120, 'make.log')
print(source / 'src/ngspice')
