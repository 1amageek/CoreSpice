#!/usr/bin/env python3
"""Acquire the unchanged official CMG release and prepare exact DC inputs."""
from argparse import ArgumentParser
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import json
import shutil
import signal
import ssl
import tarfile
import urllib.request

BUILD = Path(__file__).resolve().parents[2] / 'OSDIDCVerification' / 'build.py'
SPEC = spec_from_file_location('osdi_dc_build', BUILD)
DC = module_from_spec(SPEC)
SPEC.loader.exec_module(DC)
PAGE = 'https://www.bsim.berkeley.edu/models/bsimcmg/'
ARCHIVE = 'https://www.bsim.berkeley.edu/wp-content/uploads/BSIMCMG/BSIM-CMG_112.1.0_04282026.tar.gz'
ARCHIVE_SHA = '9c70a7c9fcfafe66fb1582655bbfd36714b90ecba137a9dd83c76b3a0bd9e50a'
PROFILE_SHA = '18237179c11753b1d2af87e21e00a7115e1a62925f956683fcf54cb9236ffbe1'


def reference(path):
    return {'path': str(path.resolve(strict=True)), 'sha256': DC.digest(path)}


def fetch(url, destination, maximum):
    context = ssl.create_default_context(cafile='/etc/ssl/cert.pem')
    with urllib.request.urlopen(url, timeout=30, context=context) as response, destination.open('xb') as output:
        total = 0
        while chunk := response.read(65536):
            total += len(chunk)
            if total > maximum:
                raise ValueError('Official download byte limit exceeded.')
            output.write(chunk)


def qualify(args):
    compiler = args.compiler.resolve(strict=True)
    profile = args.compiler_profile_receipt.resolve(strict=True)
    header = args.header.resolve(strict=True)
    point_oracle = args.point_oracle.resolve(strict=True)
    for path, expected in [(compiler, DC.COMPILER_SHA), (profile, PROFILE_SHA), (header, DC.HEADER_SHA)]:
        if DC.digest(path) != expected:
            raise ValueError(f'Pinned qualification identity mismatch: {path}')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    commands = []
    fetch(PAGE, output / 'official-page.html', 1024 * 1024)
    if ARCHIVE.encode() not in (output / 'official-page.html').read_bytes():
        raise ValueError('Official page no longer advertises the pinned standard archive.')
    archive = output / 'BSIM-CMG_112.1.0_04282026.tar.gz'
    fetch(ARCHIVE, archive, 64 * 1024 * 1024)
    if DC.digest(archive) != ARCHIVE_SHA:
        raise ValueError('Official standard release archive identity changed.')
    sources = output / 'official-release'
    sources.mkdir()
    total = 0
    with tarfile.open(archive) as stream:
        for member in stream:
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts or member.issym() or member.islnk():
                raise ValueError('Unsafe release archive entry.')
            target = sources / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                total += member.size
                if total > 128 * 1024 * 1024:
                    raise ValueError('Unpacked release byte limit exceeded.')
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as input_stream, target.open('xb') as destination:
                    shutil.copyfileobj(input_stream, destination)
            else:
                raise ValueError('Unsupported release archive entry.')
    if 'Educational Community License, Version 2.0' not in (sources / 'LICENSE.txt').read_text():
        raise ValueError('Unexpected official model license.')
    shutil.copyfile(profile, output / 'compiler-profile-receipt.json')
    shutil.copyfile(header, output / 'osdi_0_4.h')
    requests = output / 'requests.json'
    shutil.copyfile(Path(__file__).with_name('requests.json'), requests)
    source_files = [reference(path) for path in sorted((sources / 'code').iterdir()) if path.is_file()]
    version = DC.run([compiler, '--version'], output, 'compiler-version', commands)
    if '--full-residuals' not in DC.run([compiler, '--help'], output, 'compiler-help', commands):
        raise ValueError('Pinned compiler profile unavailable.')
    library = output / 'bsimcmg112-full-residuals.osdi'
    DC.run([compiler, '--full-residuals', '-O', '1', '--target', 'aarch64-apple-darwin',
            '-I', sources / 'code', sources / 'code' / 'bsimcmg.va', '-o', library],
           output, 'compile-cmg', commands)
    DC.run(['/usr/bin/codesign', '--verify', '--verbose=2', library], output, 'verify-signature', commands)
    # The independent existing point observer records actual descriptor natures and parameters.
    probes = ['type', 'l', 'nfin', 'rdsmod', 'shmod', 'rth0', 'rdw', 'rsw']
    point = json.loads(DC.run([point_oracle, library, '0', '300.15', '4'] +
                             ['r:' + name for name in probes], output, 'descriptor-point', commands))
    if point['descriptor'] != 'bsimcmg_va' or point['stateCount'] != 0:
        raise AssertionError('Unexpected actual CMG descriptor or state requirements.')
    if point['nodes'][:5] != ['d', 'g', 's', 'e', 't']:
        raise AssertionError('Unexpected actual CMG terminal order.')
    if point['nodeMetadata'][4] != {'units': 'K', 'residualUnits': 'W', 'isFlow': False}:
        raise AssertionError('CMG thermal nature metadata mismatch.')
    DC.save(output / 'descriptor-point.json', point)
    receipt = {'schema': 'corespice.osdi.model-preparation.v1', 'family': 'CMG', 'version': '112.1.0',
               'status': 'prepared', 'qualificationScope': 'native artifact and representative DC inputs; circuit qualification requires capture and CoreSpice comparison',
               'officialSourceURL': PAGE, 'officialArchiveURL': ARCHIVE,
               'officialPage': reference(output / 'official-page.html'), 'archive': reference(archive),
               'license': reference(sources / 'LICENSE.txt'), 'notice': reference(sources / 'NOTICE.txt'),
               'sourceFiles': source_files, 'compiler': dict(reference(compiler), version=version.strip()),
               'compilerProfileReceipt': reference(profile), 'header': reference(header),
               'artifact': reference(library), 'builder': reference(Path(__file__)), 'runner': reference(BUILD),
               'pointOracle': reference(point_oracle), 'descriptorPoint': reference(output / 'descriptor-point.json'),
               'requests': reference(requests), 'commands': commands}
    DC.save(output / 'artifact-receipt.json', receipt)
    fragment = {'schema': 'corespice.osdi.model-fragment.v1', 'family': 'CMG', 'version': '112.1.0',
                'officialSourceURL': PAGE,
                'library': dict(reference(library), id='cmg', descriptorIndex=0, descriptorName='bsimcmg_va'),
                'sourceFiles': source_files, 'compiler': reference(compiler),
                'compilerProfileReceipt': reference(profile), 'requests': reference(requests),
                'provenanceReceipt': reference(output / 'artifact-receipt.json')}
    DC.save(output / 'fragment.json', fragment)
    print(json.dumps({'fragment': str(output / 'fragment.json'), 'artifact': fragment['library']}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    for name in ['compiler', 'compiler-profile-receipt', 'header', 'point-oracle', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    def interrupt(signum, frame):
        raise KeyboardInterrupt(f'Model qualification interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupt)
    qualify(parser.parse_args())
