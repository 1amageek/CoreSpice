#!/usr/bin/env python3
"""Capture independent native OSDI circuit references and immutable provenance."""
from argparse import ArgumentParser
from hashlib import sha256
from pathlib import Path
import json
import math
import os
import platform
import resource
import shutil
import signal
import subprocess
import time

HEADER_SHA = '0f3eeb9ef3c9f0bea9b3c59f34c632555e2367f6e28722e219d8c3f1d655a16f'
COMPILER_SHA = '386a0f9b52e083c3f15f3642ef76937def3258c16e8f270fa797a853941f913c'
BSIM_SHA = '55b05d39103bc927251ae9ba43d7984b271016b70127a074cda9657abd4a8e38'
BSIM_SOURCE_SHA = '4db89e3997e9eec1fd5949cf2751f415a483d37b61cdd37aabd1febfc5cb7fb8'
PROFILE_RECEIPT_SHA = '18237179c11753b1d2af87e21e00a7115e1a62925f956683fcf54cb9236ffbe1'
MAX_INPUT_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 4 * 1024 * 1024


def digest(path):
    h = sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def read_json(path):
    path = Path(path)
    if path.stat().st_size > MAX_INPUT_BYTES:
        raise ValueError('Input JSON exceeds one MiB.')
    def reject(value):
        raise ValueError(f'Nonfinite JSON value: {value}')
    return json.loads(path.read_text(), parse_constant=reject)


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write('\n')


def child_limits():
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES))
    resource.setrlimit(resource.RLIMIT_CPU, (30, 30))


def run(argv, output, label, receipts, expected=0):
    arguments = [str(item) for item in argv]
    if len(arguments) > 8192 or sum(len(item.encode()) + 1 for item in arguments) > MAX_INPUT_BYTES:
        raise ValueError('Subprocess argument bound exceeded.')
    started = time.monotonic()
    stdout_path, stderr_path = output / (label + '.stdout'), output / (label + '.stderr')
    with stdout_path.open('xb') as stdout, stderr_path.open('xb') as stderr:
        process = subprocess.Popen(arguments, stdout=stdout, stderr=stderr,
                                   start_new_session=True, preexec_fn=child_limits)
        try:
            code = process.wait(timeout=30)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            raise
    for path in (stdout_path, stderr_path):
        if path.stat().st_size > MAX_OUTPUT_BYTES:
            raise RuntimeError(f'{label}: child output limit exceeded.')
    receipts.append({'argv': arguments, 'exitCode': code, 'seconds': time.monotonic() - started,
                     'stdoutSHA256': digest(stdout_path), 'stderrSHA256': digest(stderr_path)})
    if code != expected:
        raise RuntimeError(f'{label}: expected exit {expected}, got {code}: {stderr_path.read_text()[:2048]}')
    return stdout_path.read_text()


def command(oracle, libraries, case):
    args = [str(oracle)]
    for dev in case['devices']:
        library = libraries[dev['library']]
        args += ['--device', dev['id'], library['path'], str(dev['descriptorIndex']),
                 repr(dev['temperatureKelvin']), str(dev['connectedTerminalCount'])]
        for name, net in dev['terminals'].items():
            args += ['--terminal', dev['id'], name, net]
        for p in dev['parameters']:
            value = p['value']
            args += ['--parameter', dev['id'], p['scope'], value['kind'], p['name'], str(value[value['kind']])]
        for index, value in enumerate(dev['previousState']):
            args += ['--previous-state', dev['id'], str(index), repr(value)]
    for name, flag in [('resistors', '--resistor'), ('voltageSources', '--voltage-source'),
                       ('currentSources', '--current-source')]:
        for element in case[name]:
            args += [flag, element['id'], element['positive'], element['negative'], repr(element['value'])]
    for key, value in case['initialUnknowns'].items():
        args += ['--initial', key, repr(value)]
    policy = case['policy']
    for key, flag in [('unknownAbsoluteTolerances', '--unknown-atol'),
                      ('equationAbsoluteTolerances', '--equation-atol')]:
        for unit, value in policy[key].items():
            args += [flag, unit, repr(value)]
    args += ['--reltol', repr(policy['relativeTolerance']), '--max-iterations', str(policy['maximumIterations']),
             '--max-backtracks', str(policy['maximumBacktracks'])]
    return args


def candidate_arguments(reference, exclude=None, perturb=None):
    args = []
    for row in reference['unknowns']:
        if row['id'] == exclude:
            continue
        value = row['value'] + (perturb[1] if perturb and row['id'] == perturb[0] else 0)
        args += ['--candidate', row['id'], repr(value)]
    return args


def check_analytic(case, result):
    if not case['analyticUnknowns']:
        return 0
    actual = {row['id']: row for row in result['unknowns']}
    if set(actual) != set(case['analyticUnknowns']):
        raise AssertionError(f'{case["id"]}: analytic comparison must cover every unknown: {set(actual)}')
    for key, expected in case['analyticUnknowns'].items():
        row = actual[key]
        tolerance = case['policy']['unknownAbsoluteTolerances'][row['unit']]
        tolerance += case['policy']['relativeTolerance'] * abs(expected)
        if abs(row['value'] - expected) > tolerance:
            raise AssertionError(f'{case["id"]} {key}: {row["value"]} != {expected}, tolerance {tolerance}')
    return len(actual)


def build(args):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('This qualification requires macOS arm64 Native CPU.')
    here = Path(__file__).resolve().parent
    fixtures = here.parents[1] / 'Tests' / 'CoreSpiceOSDITests' / 'Fixtures'
    explicit = {'compiler': (args.compiler, COMPILER_SHA), 'BSIM': (args.bsim, BSIM_SHA),
                'BSIM source': (args.bsim_source, BSIM_SOURCE_SHA),
                'compiler-profile receipt': (args.compiler_profile_receipt, PROFILE_RECEIPT_SHA),
                'header': (here / 'osdi_0_4.h', HEADER_SHA)}
    for name, (path, expected) in explicit.items():
        if digest(path) != expected:
            raise RuntimeError(f'{name}: pinned identity mismatch.')
    bsim_receipt = read_json(args.bsim_receipt)
    profile_receipt = read_json(args.compiler_profile_receipt)
    if (bsim_receipt['profile'] != 'full-residuals' or bsim_receipt['sourceSHA256'] != BSIM_SOURCE_SHA
            or bsim_receipt['artifact']['sha256'] != BSIM_SHA
            or bsim_receipt['compiler']['sha256'] != COMPILER_SHA
            or bsim_receipt['headerSHA256'] != HEADER_SHA
            or bsim_receipt['compilerProfileReceiptSHA256'] != PROFILE_RECEIPT_SHA
            or profile_receipt['compiler']['sha256'] != COMPILER_SHA
            or profile_receipt['passed'] is not True or profile_receipt['sourceUnchanged'] is not True):
        raise RuntimeError('Artifact/compiler profile receipts disagree with the selected immutable inputs.')
    requests = read_json(fixtures / 'requests.json')
    if requests['schema'] != 'corespice.osdi.dc-inputs.v1' or not 1 <= len(requests['cases']) <= 64:
        raise ValueError('Unsupported request schema or case count.')
    if len({case['id'] for case in requests['cases']}) != len(requests['cases']):
        raise ValueError('Duplicate case IDs.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    snapshots = output / 'input-snapshots'
    snapshots.mkdir()
    sources = []
    for source in [here / 'oracle.c', here / 'build.py', here / 'osdi_0_4.h',
                   *sorted(fixtures.glob('*.va')), *sorted(fixtures.glob('*.vams')), fixtures / 'requests.json']:
        destination = snapshots / source.name
        shutil.copyfile(source, destination)
        sources.append({'name': source.name, 'sourcePath': str(source), 'snapshotPath': str(destination),
                        'sha256': digest(destination)})
    for name, source in [('bsim-artifact-receipt.json', args.bsim_receipt),
                         ('compiler-profile-receipt.json', args.compiler_profile_receipt)]:
        shutil.copyfile(source, snapshots / name)
    clang = Path(shutil.which(str(args.clang)) or str(args.clang)).resolve(strict=True)
    compiler = args.compiler.resolve(strict=True)
    bsim = args.bsim.resolve(strict=True)
    receipts = []
    started = time.monotonic()
    run([clang, '--version'], output, 'clang-version', receipts)
    run([compiler, '--version'], output, 'compiler-version', receipts)
    help_text = run([compiler, '--help'], output, 'compiler-help', receipts)
    if '--full-residuals' not in help_text:
        raise RuntimeError('Required compiler profile unavailable.')
    oracle = output / 'oracle'
    run([clang, '-std=c17', '-O1', '-Wall', '-Wextra', '-Werror', snapshots / 'oracle.c',
         '-o', oracle], output, 'oracle-build', receipts)
    libraries = {'bsim': {'id': 'bsim', 'path': str(bsim), 'sha256': BSIM_SHA,
                          'descriptorIndex': 0, 'descriptorName': 'bsimbulk'}}
    for source in sorted(snapshots.glob('*.va')):
        destination = output / (source.stem + '.osdi')
        run([compiler, '--full-residuals', '-O', '1', '--target', 'aarch64-apple-darwin',
             '-I', snapshots, source, '-o', destination], output, 'compile-' + source.stem, receipts)
        libraries[source.stem] = {'id': source.stem, 'path': str(destination), 'sha256': digest(destination),
                                  'descriptorIndex': 0, 'descriptorName': source.stem}
    cases, analytic_checks, validation_checks = [], 0, 0
    for request in requests['cases']:
        base = command(oracle, libraries, request)
        expected = request['expectedOutcome']
        raw = run(base + ['--mode', 'solve'], output, 'solve-' + request['id'], receipts,
                  expected=0 if expected == 'converged' else 3)
        result = json.loads(raw)
        if result['status'] != expected:
            raise AssertionError(f'{request["id"]}: expected {expected}, got {result["status"]}')
        analytic_checks += check_analytic(request, result)
        if expected == 'converged':
            if any(row['normalizedResidual'] > 1 for row in result['unknowns']):
                raise AssertionError('Completed reference has unsatisfied physical equations.')
            validated = json.loads(run(base + ['--mode', 'validate'] + candidate_arguments(result),
                                       output, 'validate-' + request['id'], receipts))
            if validated['status'] != 'valid':
                raise AssertionError('Independent result failed physical re-evaluation.')
            validation_checks += 1
        for dev in result['devices']:
            key = next(item['library'] for item in request['devices'] if item['id'] == dev['id'])
            if key == 'bsim':
                libraries[key]['descriptorName'] = dev['descriptorName']
            elif dev['descriptorName'] != libraries[key]['descriptorName']:
                raise AssertionError('Compiled descriptor name mismatch.')
        cases.append({'id': request['id'], 'input': request, 'reference': result,
                      'validationBaseCommand': base + ['--mode', 'validate']})
    first = next(case for case in cases if case['id'] == 'linear-current')
    base = first['validationBaseCommand']
    reference = first['reference']
    broken = json.loads(run(base + candidate_arguments(reference, perturb=('net:p', .01)),
                            output, 'reject-perturbed-physical-state', receipts, expected=3))
    if broken['status'] != 'invalid' or not any(row['normalizedResidual'] > 1 for row in broken['candidateUnknowns']):
        raise AssertionError('A wrong physical solution was accepted.')
    missing = json.loads(run(base + candidate_arguments(reference, exclude='net:p'),
                             output, 'reject-incomplete-candidate', receipts, expected=2))
    duplicate = json.loads(run(base + candidate_arguments(reference) + ['--candidate', 'net:p', '.3'],
                               output, 'reject-duplicate-candidate', receipts, expected=2))
    if missing['status'] != 'failed' or duplicate['status'] != 'failed':
        raise AssertionError('Malformed candidate accepted.')
    for name, (path, expected) in explicit.items():
        if digest(path) != expected:
            raise RuntimeError(f'{name}: input changed during capture.')
    result = {'schema': 'corespice.osdi.dc-manifest.v1', 'status': 'passed',
              'libraries': list(libraries.values()), 'cases': cases, 'sources': sources,
              'oracle': {'path': str(oracle), 'sha256': digest(oracle)},
              'compiler': {'path': str(compiler), 'sha256': COMPILER_SHA},
              'clang': {'path': str(clang), 'sha256': digest(clang)},
              'headerSHA256': HEADER_SHA, 'bsimSourceSHA256': BSIM_SOURCE_SHA,
              'compilerProfileReceiptSHA256': PROFILE_RECEIPT_SHA,
              'bsimArtifactReceiptSHA256': digest(args.bsim_receipt),
              'analyticUnknownChecks': analytic_checks, 'revalidationChecks': validation_checks,
              'negativeValidationChecks': 3, 'commands': receipts, 'seconds': time.monotonic() - started}
    save(output / 'manifest.json', result)
    print(json.dumps({'manifest': str(output / 'manifest.json'), 'status': 'passed',
                      'cases': len(cases), 'analyticUnknownChecks': analytic_checks,
                      'revalidationChecks': validation_checks, 'seconds': result['seconds']}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, required=True)
    parser.add_argument('--compiler-profile-receipt', type=Path, required=True)
    parser.add_argument('--bsim', type=Path, required=True)
    parser.add_argument('--bsim-source', type=Path, required=True)
    parser.add_argument('--bsim-receipt', type=Path, required=True)
    parser.add_argument('--clang', default='clang')
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args())
