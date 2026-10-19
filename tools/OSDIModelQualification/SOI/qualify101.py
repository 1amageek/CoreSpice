#!/usr/bin/env python3
"""Compile unchanged official SOI101 and independently capture its frozen DC envelope."""
from argparse import ArgumentParser
from hashlib import sha256
from pathlib import Path, PurePosixPath
import importlib.util
import json
import platform
import shutil
import sys
import tarfile

PARENT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PARENT))
import family_profile as admission

URL = 'https://si2.org/wp-content/uploads/CMC/models/BSIM-SOI_101.0.0_09152026.tar.gz'
ARCHIVE_SHA = 'bfa1fbd3014a50591879511ce9055f66e0d1c73f85c19763e4fd4ef215c80082'
MEMBERS = {'code/bsimsoi.va': 'cba0d2de068e86b026d9580c9d8ab78f592ccc3d9dc8efb98fb5d67182be0a87',
           'NOTICE.txt': '3a5a1acf66411dfafae606e48ffba657d7cd7a14e626c81aae6a0dd776ba3cb1',
           'LICENSE.txt': '4d202b27df0df53f021ad2ba5cb2d0e7e62a9025e6a9786952c67be7111edea8'}


def qualify(args):
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise ValueError('SOI101 qualification requires native macOS arm64.')
    specifications, requests, _ = admission.load('latest-soi101-v1')
    specification = specifications['SOI']
    spec = importlib.util.spec_from_file_location('soi101_capture', PARENT / 'capture.py')
    capture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capture)
    baseline, tool = capture.load_baseline(args.oracle_manifest.resolve(strict=True))
    compiler = args.compiler.resolve(strict=True)
    profile = args.compiler_profile_receipt.resolve(strict=True)
    archive = args.archive.resolve(strict=True)
    if (archive.stat().st_size > 16 * 1024 * 1024 or admission.digest(archive) != ARCHIVE_SHA
            or admission.digest(compiler) != specification['compilerSHA256']
            or admission.digest(profile) != specification['compilerProfileReceiptSHA256']):
        raise ValueError('Official archive or qualified compiler/profile identity mismatch.')
    qualification = admission.read(profile)
    if (qualification['schema'] != 'openvaf.precision.compiler.delta-qualification.v1'
            or qualification['status'] != 'passed' or qualification['sourceUnchanged'] is not True
            or qualification['compiler']['sha256'] != specification['compilerSHA256']
            or qualification['semanticProfileSHA256'] != specification['semanticProfileSHA256']):
        raise ValueError('The selected compiler receipt does not qualify this source-program profile.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    acquired = args.source_directory.resolve(strict=True) if args.source_directory is not None else output / 'acquisition'
    if args.source_directory is None:
        acquired.mkdir()
    extracted = set()
    with tarfile.open(archive, 'r:gz') as package:
        for member in package:
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or '..' in relative.parts or member.issym() or member.islnk():
                raise ValueError('Unsafe official archive member.')
            name = str(relative)
            if name not in MEMBERS:
                continue
            if name in extracted or not member.isfile() or member.size > 1024 * 1024:
                raise ValueError('Duplicate or oversized required source/notice member.')
            target = acquired / name
            with package.extractfile(member) as source:
                contents = source.read(1024 * 1024 + 1)
            if sha256(contents).hexdigest() != MEMBERS[name]:
                raise ValueError('Official archive source/notice member identity mismatch.')
            if args.source_directory is None:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(contents)
            if admission.digest(target) != MEMBERS[name]:
                raise ValueError('Unchanged official source/notice identity mismatch.')
            extracted.add(name)
    if extracted != set(MEMBERS):
        raise ValueError('Official archive omits the exact source or notices.')
    source = acquired / 'code/bsimsoi.va'
    request_path = output / 'requests.json'
    shutil.copyfile(admission.ROOT / specification['requestPath'], request_path)
    commands = []
    compilation = None
    if args.library is not None:
        library_path = args.library.resolve(strict=True)
        receipt_path = args.compilation_receipt.resolve(strict=True)
        if (admission.digest(library_path) != specification['artifactSHA256']
                or admission.digest(receipt_path) != specification['retainedCompilationReceiptSHA256']):
            raise ValueError('Retained exact image/compilation receipt identity mismatch.')
        retained = admission.read(receipt_path)
        argv = retained['command']
        if (retained['exitCode'] != 0 or retained['sourceSHA256'] != MEMBERS['code/bsimsoi.va']
                or retained['compilerSHA256'] != specification['compilerSHA256']
                or retained['semanticProfileSHA256'] != specification['semanticProfileSHA256']
                or retained['imageSHA256'] != admission.digest(library_path)
                or '--full-residuals' not in argv or '--precision-v1' not in argv
                or argv[argv.index('--precision-v1') + 1] != specification['semanticProfileSHA256']):
            raise ValueError('Retained compilation does not bind this source/compiler/program/image.')
        compilation = {'path': str(receipt_path), 'sha256': admission.digest(receipt_path),
                       'mode': 'unchanged-exact-image-reuse'}
    else:
        library_path = output / 'bsimsoi101-full-residuals.osdi'
        command = [compiler, '--full-residuals', '--precision-v1', specification['semanticProfileSHA256'],
                   '-o', library_path, source]
        tool.run(command, output, 'compile-soi101', commands)
    library = {'id': specification['libraryID'], 'path': str(library_path),
               'sha256': admission.digest(library_path), 'descriptorIndex': specification['descriptorIndex'],
               'descriptorName': specification['descriptorName']}
    admission.check_library(specification, library)
    oracle = Path(baseline['oracle']['path'])
    cases = []
    for identifier, request in requests['SOI'].items():
        argv = tool.command(oracle, {library['id']: library}, request)
        result = json.loads(tool.run(argv + ['--mode', 'solve'], output, 'solve-' + identifier, commands))
        if (result['status'] != request['expectedOutcome'] or any(
                row['normalizedResidual'] > 1 for row in result['unknowns'])):
            raise ValueError(identifier + ': unchanged physical DC acceptance failed.')
        device = result['devices'][0]
        if (device['descriptorName'] != specification['descriptorName']
                or [node['name'] for node in device['rawNodes'][:6]] != ['d', 'g', 's', 'e', 'b', 't']):
            raise ValueError(identifier + ': actual six-terminal SOI101 topology mismatch.')
        if identifier.endswith('hot-series-thermal'):
            private = {row['id']: row for row in result['unknowns']}
            thermal = private.get('device:M1:node:t')
            if thermal is None or thermal['unit'] != 'K' or thermal['residualUnit'] != 'W' or thermal['value'] <= 0:
                raise ValueError(identifier + ': private thermal balance was not exercised.')
            if not any('device:M1:node:' + name in private for name in ['di', 'si', 'gi', 'gm']):
                raise ValueError(identifier + ': series/gate coordinates were not retained.')
        validated = json.loads(tool.run(argv + ['--mode', 'validate'] + tool.candidate_arguments(result),
                              output, 'validate-' + identifier, commands))
        if validated['status'] != 'valid':
            raise ValueError(identifier + ': complete candidate revalidation failed.')
        cases.append({'id': identifier, 'family': 'SOI', 'input': request, 'reference': result,
                      'validationBaseCommand': argv + ['--mode', 'validate']})
    for name, expected in MEMBERS.items():
        if admission.digest(acquired / name) != expected:
            raise ValueError('Official source/notice changed during qualification.')
    if (admission.digest(archive) != ARCHIVE_SHA or admission.digest(compiler) != specification['compilerSHA256']
            or admission.digest(profile) != specification['compilerProfileReceiptSHA256']
            or admission.digest(request_path) != specification['requestSHA256']
            or admission.digest(library_path) != library['sha256']
            or (compilation is not None and admission.digest(compilation['path']) != compilation['sha256'])):
        raise ValueError('An admitted compiler/archive/request input changed during qualification.')
    def reference(path):
        return {'path': str(path), 'sha256': admission.digest(path)}
    provenance = {'schema': 'corespice.osdi.model-provenance.v1', 'family': 'SOI', 'version': '101.0.0',
        'status': 'passed', 'officialSourceURL': URL, 'archive': dict(reference(archive), url=URL),
        'sourceFiles': [reference(source)], 'license': reference(acquired / 'LICENSE.txt'),
        'notice': reference(acquired / 'NOTICE.txt'), 'compiler': reference(compiler),
        'compilerProfileReceipt': reference(profile), 'semanticProfileSHA256': specification['semanticProfileSHA256'],
        'artifact': library, 'requests': reference(request_path), 'sourceUnchanged': True,
        'retainedCompilation': compilation,
        'oracle': baseline['oracle'], 'commands': commands,
        'tool': reference(Path(__file__)), 'authority': reference(admission.AUTHORITY),
        'scope': 'Frozen finite DC circuits and complete-vector validation; no dynamic, all-corner or foundry claim'}
    provenance_path = output / 'provenance.json'
    tool.save(provenance_path, provenance)
    tool.save(output / 'manifest.json', {'schema': 'corespice.osdi.dc-manifest.v1', 'status': 'passed',
        'libraries': [library], 'cases': cases, 'oracle': baseline['oracle'], 'commands': commands})
    fragment = {'schema': 'corespice.osdi.model-fragment.v1', 'family': 'SOI', 'version': '101.0.0',
        'officialSourceURL': URL, 'library': library, 'sourceFiles': provenance['sourceFiles'],
        'compiler': reference(compiler), 'compilerProfileReceipt': reference(profile),
        'requests': reference(request_path), 'provenanceReceipt': reference(provenance_path)}
    tool.save(output / 'fragment.json', fragment)
    print(json.dumps({'status': 'passed', 'fragment': str(output / 'fragment.json'), 'caseCount': len(cases)}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    for name in ['archive', 'compiler', 'compiler-profile-receipt', 'oracle-manifest', 'output']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--library', type=Path, help='Reuse the exact retained SOI101 image instead of compiling again')
    parser.add_argument('--source-directory', type=Path, help='Reuse an existing extracted official code/NOTICE/LICENSE tree without copying it')
    parser.add_argument('--compilation-receipt', type=Path, help='Required with --library; exact retained compilation authority')
    arguments = parser.parse_args()
    if (arguments.library is None) != (arguments.compilation_receipt is None):
        parser.error('--library and --compilation-receipt must be supplied together')
    qualify(arguments)
