#!/usr/bin/env python3
"""Acquire unchanged Berkeley BSIM-IMG and capture bounded native DC evidence."""
from argparse import ArgumentParser
from hashlib import sha256
from pathlib import Path
import importlib.util
import io
import json
import platform
import shutil
import ssl
import tarfile
import time
import urllib.request

URL = 'https://www.bsim.berkeley.edu/wp-content/uploads/BSIMIMG/BSIM-IMG_103.1.0_09102024.tar.gz'
ARCHIVE_SHA = '3c90d33f60951980e4f28528af083a36ba12f63e37d1a4f4ac9742a56e5cf8d2'
COMPILER_SHA = '386a0f9b52e083c3f15f3642ef76937def3258c16e8f270fa797a853941f913c'
PROFILE_SHA = '18237179c11753b1d2af87e21e00a7115e1a62925f956683fcf54cb9236ffbe1'
HEADER_SHA = '0f3eeb9ef3c9f0bea9b3c59f34c632555e2367f6e28722e219d8c3f1d655a16f'


def main(args):
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise RuntimeError('Qualification requires macOS arm64.')
    here = Path(__file__).resolve().parent
    helper_path = here.parents[1] / 'OSDIDCVerification' / 'build.py'
    spec = importlib.util.spec_from_file_location('dc_capture', helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    compiler = args.compiler.resolve(strict=True)
    profile = args.compiler_profile_receipt.resolve(strict=True)
    oracle_manifest_path = args.oracle_manifest.resolve(strict=True)
    oracle_manifest = helper.read_json(oracle_manifest_path)
    oracle = Path(oracle_manifest['oracle']['path']).resolve(strict=True)
    point_oracle = args.point_oracle.resolve(strict=True)
    header = helper_path.parent / 'osdi_0_4.h'
    for path, identity in [(compiler, COMPILER_SHA), (profile, PROFILE_SHA),
                           (oracle, oracle_manifest['oracle']['sha256']), (header, HEADER_SHA)]:
        if helper.digest(path) != identity:
            raise RuntimeError(f'Pinned input mismatch: {path}')
    profile_data = helper.read_json(profile)
    if (profile_data['compiler']['sha256'] != COMPILER_SHA or
            profile_data['passed'] is not True or profile_data['sourceUnchanged'] is not True):
        raise RuntimeError('Compiler qualification receipt rejected.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    acquired = output / 'acquisition'
    acquired.mkdir()
    started = time.monotonic()
    with urllib.request.urlopen(URL, timeout=30, context=ssl.create_default_context(cafile='/etc/ssl/cert.pem')) as response:
        chunks, count = [], 0
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            count += len(chunk)
            if count > 16 * 1024 * 1024 or time.monotonic() - started > 60:
                raise RuntimeError('Acquisition byte/time bound exceeded.')
            chunks.append(chunk)
        archive = b''.join(chunks)
        final_url = response.url
    if sha256(archive).hexdigest() != ARCHIVE_SHA:
        raise RuntimeError('Official archive identity mismatch.')
    archive_path = acquired / URL.rsplit('/', 1)[1]
    archive_path.write_bytes(archive)
    source_files = []
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        for member in tar.getmembers():
            path = acquired / member.name
            if not path.resolve().is_relative_to(acquired) or member.issym() or member.islnk():
                raise RuntimeError('Unsafe archive member.')
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile() and member.size <= 16 * 1024 * 1024:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(tar.extractfile(member).read())
                if path.suffix in ('.va', '.include'):
                    source_files.append({'path': str(path), 'sha256': helper.digest(path)})
            else:
                raise RuntimeError('Unsupported archive member.')
    if len(source_files) != 5:
        raise RuntimeError('Unexpected official source inventory.')
    requests_path = output / 'requests.json'
    shutil.copyfile(here / 'requests.json', requests_path)
    requests = helper.read_json(requests_path)
    commands = []
    artifact = output / 'bsimimg103-full-residuals.osdi'
    compile_argv = [compiler, '--full-residuals', '-O', '1', '--target', 'aarch64-apple-darwin',
                    acquired / 'code' / 'bsimimg.va', '-o', artifact]
    helper.run(compile_argv, output, 'compile', commands)
    library = {'id': 'img', 'path': str(artifact), 'sha256': helper.digest(artifact),
               'descriptorIndex': 0, 'descriptorName': 'bsimimg'}
    point = json.loads(helper.run([point_oracle, artifact, '0', '300.15', '4',
                                  'r:TYPE', 'r:L', 'r:W', 'r:DTEMP', 'r:SHMOD',
                                  'r:RDSMOD', 'r:RGATEMOD', 'r:DELHCI'],
                                 output, 'metadata-point', commands))
    if point['descriptor'] != 'bsimimg' or point['stateCount'] != 0:
        raise AssertionError('Unexpected IMG descriptor/state count.')
    if point['nodes'] != ['d', 'fg', 's', 'bg', 't', 'di', 'si', 'ge', 'gi', 'n']:
        raise AssertionError('Unexpected IMG node order.')
    for name, metadata in zip(point['nodes'], point['nodeMetadata']):
        expected = ('K', 'W') if name == 't' else ('V', 'A')
        if (metadata['units'], metadata['residualUnits']) != expected or metadata['isFlow']:
            raise AssertionError('Unexpected raw node nature.')
    parameter_metadata = {row['names'][0]: row for row in point['parameters']}
    for name in ['L', 'W', 'DTEMP']:
        if (parameter_metadata[name]['kind'], parameter_metadata[name]['type']) != (1, 0):
            raise AssertionError('Instance real parameter contract changed.')
    for name in ['TYPE', 'SHMOD', 'RDSMOD', 'RGATEMOD']:
        if (parameter_metadata[name]['kind'], parameter_metadata[name]['type']) != (0, 1):
            raise AssertionError('Model integer parameter contract changed.')
    if parameter_metadata['DELHCI']['kind'] != 0:
        raise AssertionError('Recorded compiler DELHCI limitation changed.')
    cases = []
    for case in requests['cases']:
        base = helper.command(oracle, {'img': library}, case)
        result = json.loads(helper.run(base + ['--mode', 'solve'], output, 'solve-' + case['id'], commands))
        if result['status'] != 'converged' or any(row['normalizedResidual'] > 1 for row in result['unknowns']):
            raise AssertionError(f'{case["id"]}: physical DC convergence failed.')
        validation = json.loads(helper.run(base + ['--mode', 'validate'] + helper.candidate_arguments(result),
                                           output, 'validate-' + case['id'], commands))
        if validation['status'] != 'valid':
            raise AssertionError('Complete-vector physical revalidation failed.')
        cases.append({'id': case['id'], 'input': case, 'reference': result,
                      'validationBaseCommand': base + ['--mode', 'validate']})
    by_id = {case['id']: case['reference'] for case in cases}
    def current(case_id):
        return next(row['value'] for row in by_id[case_id]['unknowns'] if row['id'] == 'branch:VD')
    for polarity, sign in [('n', -1), ('p', 1)]:
        if current(f'img-{polarity}-forward') * sign <= 1e-8:
            raise AssertionError('Drain current polarity/magnitude check failed.')
        if abs(current(f'img-{polarity}-forward') - current(f'img-{polarity}-backgate')) <= 1e-8:
            raise AssertionError('Independent backgate response absent.')
    if abs(current('img-n-forward') - current('img-n-hot')) <= 1e-8:
        raise AssertionError('Ambient temperature response absent.')
    series = {row['id']: row for row in by_id['img-n-series']['unknowns']}
    if not all(f'device:M1:node:{name}' in series for name in ['di', 'si', 'ge']):
        raise AssertionError('Representative private nodes were not retained.')
    if abs(series['device:M1:node:di']['value'] - series['net:d']['value']) <= 1e-6:
        raise AssertionError('Internal series voltage drop absent.')
    thermal = next(row for row in by_id['img-n-thermal']['unknowns'] if row['id'] == 'device:M1:node:t')
    if thermal['unit'] != 'K' or thermal['residualUnit'] != 'W' or thermal['value'] <= 0:
        raise AssertionError('Free thermal balance not exercised.')
    for item in source_files:
        if helper.digest(item['path']) != item['sha256']:
            raise RuntimeError('Official source changed during qualification.')
    receipt = {'schema': 'corespice.osdi.model-provenance.v1', 'family': 'IMG', 'version': '103.1.0',
               'officialPageURL': 'https://www.bsim.berkeley.edu/models/bsimimg/',
               'listingDate': '2024-09-11', 'sourceBannerDate': '2024-09-10',
               'archive': {'url': URL, 'finalURL': final_url, 'path': str(archive_path), 'sha256': ARCHIVE_SHA},
               'license': {'name': 'ECL-2.0', 'path': str(acquired / 'LICENSE.txt'),
                           'sha256': helper.digest(acquired / 'LICENSE.txt')},
               'notice': {'path': str(acquired / 'NOTICE.txt'), 'sha256': helper.digest(acquired / 'NOTICE.txt')},
               'compiler': {'path': str(compiler), 'sha256': COMPILER_SHA},
               'compilerProfileReceipt': {'path': str(profile), 'sha256': PROFILE_SHA},
               'header': {'path': str(header), 'sha256': HEADER_SHA},
               'sourceFiles': source_files, 'artifact': library, 'profile': 'full-residuals',
               'sourceUnchanged': True, 'pointOracle': {'path': str(point_oracle), 'sha256': helper.digest(point_oracle)},
               'oracleManifest': {'path': str(oracle_manifest_path), 'sha256': helper.digest(oracle_manifest_path)},
               'inputs': [{'path': str(path), 'sha256': helper.digest(path)} for path in
                          [Path(__file__).resolve(), helper_path, here / 'requests.json']],
               'metadataPoint': point, 'commands': commands,
               'limitations': ['Official DELHCI type="both" is compiled as model scope; instance aging assignment is unqualified.',
                               'Ordinary DC artifact/consumer checks do not qualify model physics, AC, transient or noise.'],
               'seconds': time.monotonic() - started}
    receipt_path = output / 'provenance.json'
    helper.save(receipt_path, receipt)
    manifest = {'schema': 'corespice.osdi.dc-manifest.v1', 'status': 'passed', 'libraries': [library],
                'cases': cases, 'revalidationChecks': len(cases), 'commands': commands,
                'oracle': oracle_manifest['oracle'], 'compiler': receipt['compiler']}
    helper.save(output / 'manifest.json', manifest)
    fragment = {'schema': 'corespice.osdi.model-fragment.v1', 'family': 'IMG', 'version': '103.1.0',
                'officialSourceURL': URL, 'library': library, 'sourceFiles': source_files,
                'compiler': receipt['compiler'], 'compilerProfileReceipt': receipt['compilerProfileReceipt'],
                'requests': {'path': str(requests_path), 'sha256': helper.digest(requests_path)},
                'provenanceReceipt': {'path': str(receipt_path), 'sha256': helper.digest(receipt_path)}}
    helper.save(output / 'fragment.json', fragment)
    print(json.dumps({'status': 'passed', 'fragment': str(output / 'fragment.json'), 'cases': len(cases),
                      'artifactSHA256': library['sha256'], 'seconds': receipt['seconds']}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path, required=True)
    parser.add_argument('--compiler-profile-receipt', type=Path, required=True)
    parser.add_argument('--oracle-manifest', type=Path, required=True)
    parser.add_argument('--point-oracle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    main(parser.parse_args())
