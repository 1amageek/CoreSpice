#!/usr/bin/env python3
"""Bounded test-only build and point replay for the independent MPFR oracle."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import resource
import shutil
import struct
import subprocess
import time

HERE = Path(__file__).resolve().parent
HEADER = HERE.parents[3] / 'swift-osdi/Sources/COSDI/include/OSDICompilerPrecision.h'
MAX_INPUT = 64 * 1024 * 1024
MAX_OUTPUT = 4 * 1024 * 1024


def identity(path):
    path = Path(path).resolve(strict=True)
    if path.stat().st_size > MAX_INPUT:
        raise ValueError('input_size')
    return {'path': str(path), 'bytes': path.stat().st_size,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def write_json(path, value):
    path = Path(path)
    data = (json.dumps(value, indent=2, allow_nan=False) + '\n').encode()
    if len(data) > MAX_OUTPUT:
        raise ValueError('receipt_size')
    with path.open('xb') as stream:
        stream.write(data)


def run(argv, directory, stem, timeout=30):
    """Files bound child output; no pipe accumulation or shell execution."""
    directory = Path(directory)
    out, err = directory / (stem + '.stdout'), directory / (stem + '.stderr')
    def limits():
        resource.setrlimit(resource.RLIMIT_CPU, (timeout, timeout))
        resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_OUTPUT, MAX_OUTPUT))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if shutil.disk_usage(directory).free < 64*1024*1024:
        raise RuntimeError('insufficient_validation_output_reserve')
    started = time.monotonic()
    with out.open('xb') as stdout, err.open('xb') as stderr:
        child = subprocess.Popen(['/usr/bin/time', '-l', *map(str, argv)],
                                 stdout=stdout, stderr=stderr, preexec_fn=limits,
                                 start_new_session=True, env={'PATH': '/usr/bin:/bin'})
        timed_out = False
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(child.pid, 9)
            code = child.wait()
    result = {'argv': list(map(str, argv)), 'exitCode': code,
              'timedOut': timed_out, 'seconds': time.monotonic() - started,
              'stdout': identity(out), 'stderr': identity(err),
              'limits': {'wallSeconds': timeout, 'cpuSeconds': timeout,
                         'eachOutputBytes': MAX_OUTPUT, 'children': 1}}
    write_json(directory / (stem + '-execution.json'), result)
    return result


def build(directory):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=False)
    snapshots = directory / 'inputs'
    snapshots.mkdir()
    inputs = []
    for original in (HERE / 'reference.c', HEADER, HERE / 'driver.py', HERE / 'verify.py'):
        target = snapshots / original.name
        shutil.copyfile(original, target)
        original_id, snapshot_id = identity(original), identity(target)
        if original_id['sha256'] != snapshot_id['sha256']:
            raise ValueError('concurrent_source_change')
        inputs.append({'original': original_id, 'snapshot': snapshot_id})
    libraries = [Path('/opt/homebrew/lib/libmpfr.6.dylib'),
                 Path('/opt/homebrew/lib/libgmp.10.dylib')]
    compiler = Path('/usr/bin/clang')
    binary = directory / 'precision-reference'
    argv = [compiler, '-std=c17', '-O1', '-Wall', '-Wextra', '-Werror',
            '-I' + str(snapshots), '-I/opt/homebrew/include', snapshots / 'reference.c',
            *libraries, '-o', binary]
    execution = run(argv, directory, 'compile')
    receipt = {'schema': 'corespice.independent-precision-build.v1',
               'inputs': inputs, 'compiler': identity(compiler),
               'arithmeticLibraries': [identity(x) for x in libraries],
               'arithmeticHeaders': [identity(Path('/opt/homebrew/include') / name)
                                     for name in ('mpfr.h', 'gmp.h')],
               'execution': execution}
    if execution['exitCode'] == 0 and not execution['timedOut']:
        receipt['binary'] = identity(binary)
        receipt['status'] = 'passed'
    else:
        receipt['status'] = 'failed'
    write_json(directory / 'build.json', receipt)
    if receipt['status'] != 'passed':
        raise RuntimeError('compile_failed: ' + str(directory / 'compile.stderr'))
    return binary


def points_bytes(vectors, contexts):
    if len(vectors) != 4 or len(contexts) != 2:
        raise ValueError('paired_shape')
    n = len(vectors[0])
    if n > 128 or any(len(x) != n for x in vectors):
        raise ValueError('coordinate_shape')
    if any(not math.isfinite(x) for lane in vectors for x in lane):
        raise ValueError('nonfinite_coordinate')
    for context in contexts:
        if context['mode'] not in (2, 3):
            raise ValueError('context_mode')
        if any(not math.isfinite(context[x]) for x in ('high', 'low')):
            raise ValueError('nonfinite_context')
    c, r = contexts
    return (struct.pack('<8sIIII4d', b'OSDIREF1', 1, n, c['mode'], r['mode'],
                        c['high'], c['low'], r['high'], r['low']) +
            struct.pack('<' + str(4*n) + 'd', *(x for lane in vectors for x in lane)))


def replay(binary, program, setup, vectors, contexts, directory, bits=512, work=100000000):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=False)
    if bits < 128 or bits > 4096 or work < 1 or work > 1000000000:
        raise ValueError('operating_profile')
    inputs = {key: identity(value) for key, value in
              (('binary', binary), ('program', program), ('setup', setup))}
    point = directory / 'points.bin'
    with point.open('xb') as stream:
        stream.write(points_bytes(vectors, contexts))
    inputs['points'] = identity(point)
    execution = run([binary, program, setup, point, bits, work], directory, 'point')
    receipt = {'schema': 'corespice.independent-precision-replay.v1', 'inputs': inputs,
               'precisionBits': bits, 'maximumWork': work, 'contexts': contexts,
               'vectors': vectors, 'execution': execution,
               'status': 'passed' if execution['exitCode'] == 0 and not execution['timedOut'] else 'failed'}
    write_json(directory / 'receipt.json', receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    command = sub.add_parser('build')
    command.add_argument('--output', required=True)
    command = sub.add_parser('point')
    command.add_argument('--binary', required=True)
    command.add_argument('--request', required=True,
                         help='Private paired-point JSON with exact program/setup paths, four vectors and two contexts')
    command.add_argument('--output', required=True)
    command.add_argument('--bits', type=int, default=512)
    command.add_argument('--maximum-work', type=int, default=100000000)
    args = parser.parse_args()
    if args.operation == 'build':
        print(build(args.output))
    else:
        identity(args.request)
        request = json.loads(Path(args.request).read_text())
        for key in ('program', 'setup'):
            if identity(request[key+'Path'])['sha256'] != request[key+'SHA256']:
                raise ValueError(key+'_identity_mismatch')
        receipt = replay(args.binary, request['programPath'], request['setupPath'],
                         request['vectors'], request['contexts'], args.output,
                         args.bits, args.maximum_work)
        print(json.dumps({'status': receipt['status'], 'receipt': str(Path(args.output) / 'receipt.json')}))
        if receipt['status'] != 'passed':
            raise SystemExit(2)


if __name__ == '__main__':
    main()
