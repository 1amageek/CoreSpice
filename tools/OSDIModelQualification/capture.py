#!/usr/bin/env python3
"""Merge explicitly admitted model-family DC references using the unchanged C oracle."""
from argparse import ArgumentParser
from hashlib import sha256
from pathlib import Path
import importlib.util
import json
import shutil
import sys
import time

_profile_spec = importlib.util.spec_from_file_location('osdi_family_profile', Path(__file__).with_name('family_profile.py'))
admission = importlib.util.module_from_spec(_profile_spec)
_profile_spec.loader.exec_module(admission)

COMPILER_SHA = '386a0f9b52e083c3f15f3642ef76937def3258c16e8f270fa797a853941f913c'
PROFILE_SHA = '18237179c11753b1d2af87e21e00a7115e1a62925f956683fcf54cb9236ffbe1'
HEADER_SHA = '0f3eeb9ef3c9f0bea9b3c59f34c632555e2367f6e28722e219d8c3f1d655a16f'
BSIM_SHA = '55b05d39103bc927251ae9ba43d7984b271016b70127a074cda9657abd4a8e38'
MAX_JSON_BYTES = 1024 * 1024


def digest(path):
    result = sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def read_json(path):
    path = Path(path)
    if path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError(f'JSON input exceeds one MiB: {path}')
    def reject(value):
        raise ValueError(f'Nonfinite JSON value: {value}')
    return json.loads(path.read_text(), parse_constant=reject)


def checked_file(record):
    path = Path(record['path'])
    if not path.is_absolute() or not path.is_file():
        raise ValueError('An admitted input must name an existing absolute file path.')
    expected = record['sha256']
    if (not isinstance(expected, str) or len(expected) != 64
            or any(c not in '0123456789abcdef' for c in expected) or digest(path) != expected):
        raise ValueError(f'Input identity mismatch: {path}')
    return path


def load_baseline(path):
    baseline = read_json(path)
    if baseline['schema'] != 'corespice.osdi.dc-manifest.v1' or baseline['status'] != 'passed':
        raise ValueError('Baseline is not a completed independent DC capture.')
    if (baseline['headerSHA256'] != HEADER_SHA or baseline['compiler']['sha256'] != COMPILER_SHA
            or baseline['compilerProfileReceiptSHA256'] != PROFILE_SHA):
        raise ValueError('Baseline compiler/header profile mismatch.')
    checked_file(baseline['oracle'])
    checked_file(baseline['compiler'])
    for library in baseline['libraries']:
        checked_file(library)
    if not any(lib['id'] == 'bsim' and lib['sha256'] == BSIM_SHA for lib in baseline['libraries']):
        raise ValueError('Baseline omits the unchanged approved BULK image.')
    snapshots = {}
    for record in baseline['sources']:
        source = {'path': record['snapshotPath'], 'sha256': record['sha256']}
        checked_file(source)
        if record['name'] in snapshots:
            raise ValueError('Duplicate baseline snapshot name.')
        snapshots[record['name']] = source
    if snapshots['osdi_0_4.h']['sha256'] != HEADER_SHA:
        raise ValueError('Baseline header snapshot mismatch.')
    translator = Path(snapshots['build.py']['path'])
    spec = importlib.util.spec_from_file_location('captured_osdi_dc_builder', translator)
    module = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return baseline, module


def load_fragment(path, baseline, specifications, required_requests):
    fragment = read_json(path)
    if fragment['schema'] != 'corespice.osdi.model-fragment.v1':
        raise ValueError('Unsupported model fragment schema.')
    family = fragment['family']
    if family not in specifications or family == 'BULK' or fragment['version'] != specifications[family]['version']:
        raise ValueError('Model family/version does not match the approved source target.')
    if not fragment['officialSourceURL'].startswith('https://'):
        raise ValueError('Explicit official HTTPS source identity is required.')
    if not 1 <= len(fragment['sourceFiles']) <= 128:
        raise ValueError('Source file count outside the capture profile.')
    records = [fragment['library'], fragment['compiler'], fragment['compilerProfileReceipt'],
               fragment['requests'], fragment['provenanceReceipt'], *fragment['sourceFiles']]
    for record in records:
        checked_file(record)
    specification = specifications[family]
    if (fragment['compiler']['sha256'] != specification['compilerSHA256']
            or fragment['compilerProfileReceipt']['sha256'] != specification['compilerProfileReceiptSHA256']):
        raise ValueError('Model artifact does not use the approved exact compiler profile.')
    library = fragment['library']
    admission.check_library(specification, library)
    source_hashes = {Path(record['path']).name: record['sha256'] for record in fragment['sourceFiles']}
    if (len(source_hashes) != len(fragment['sourceFiles']) or source_hashes != specification['sourceSHA256']
            or fragment['requests']['sha256'] != specification['requestSHA256']):
        raise ValueError('Family source inventory or frozen request identity mismatch.')
    provenance = read_json(fragment['provenanceReceipt']['path'])
    if (provenance['family'] != family or provenance['version'] != specification['version']
            or provenance['artifact']['path'] != library['path']
            or provenance['artifact']['sha256'] != library['sha256']
            or provenance['compiler']['sha256'] != specification['compilerSHA256']
            or provenance['compilerProfileReceipt']['sha256'] != specification['compilerProfileReceiptSHA256']
            or {Path(record['path']).name: record['sha256'] for record in provenance['sourceFiles']} != source_hashes):
        raise ValueError('Source/compiler provenance does not bind the admitted generated image.')
    if (not isinstance(library['descriptorIndex'], int) or isinstance(library['descriptorIndex'], bool)
            or not 0 <= library['descriptorIndex'] < 64 or not library['descriptorName']):
        raise ValueError('Invalid descriptor admission.')
    requests = read_json(fragment['requests']['path'])
    if requests['schema'] != 'corespice.osdi.dc-inputs.v1' or not 1 <= len(requests['cases']) <= 64:
        raise ValueError('Unsupported child DC request schema or case count.')
    if admission.unique(requests['cases'], 'request') != required_requests[family]:
        raise ValueError('Child requests do not match the selected complete finite family profile.')
    for case in requests['cases']:
        if not case['devices'] or any(dev['library'] != library['id']
                or dev['descriptorIndex'] != library['descriptorIndex'] for dev in case['devices']):
            raise ValueError('A child circuit must bind only its exact admitted descriptor.')
        if case['expectedOutcome'] not in ('converged', 'singular', 'nonconvergent'):
            raise ValueError('Unsupported expected child outcome.')
    return fragment, requests, records


def capture(args):
    started = time.monotonic()
    baseline_path = args.oracle_manifest.resolve(strict=True)
    baseline_sha = digest(baseline_path)
    baseline, tool = load_baseline(baseline_path)
    specifications, required_requests, baseline_requests = admission.load(args.profile)
    if ({case['id']: case['input'] for case in baseline['cases']}
            != admission.unique(baseline_requests, 'baseline request')
            or baseline['bsimSourceSHA256'] != specifications['BULK']['sourceSHA256']['bsimbulk.va']):
        raise ValueError('Baseline requests/source differ from the selected authority.')
    if not 1 <= len(args.fragment) <= 3:
        raise ValueError('Capture requires one to three additional family fragments.')
    fragments, seen = [], set()
    for path in args.fragment:
        fragment, requests, records = load_fragment(path, baseline, specifications, required_requests)
        if fragment['family'] in seen:
            raise ValueError('Duplicate model family fragment.')
        seen.add(fragment['family'])
        fragments.append((path.resolve(strict=True), digest(path), fragment, requests, records))
    library_ids = {item['id'] for item in baseline['libraries']}
    case_ids = {item['id'] for item in baseline['cases']}
    if len(library_ids) != len(baseline['libraries']) or len(case_ids) != len(baseline['cases']):
        raise ValueError('Baseline contains duplicate identities.')
    total_cases = len(baseline['cases'])
    for _, _, fragment, requests, _ in fragments:
        if fragment['library']['id'] in library_ids:
            raise ValueError('Duplicate library identity across families.')
        library_ids.add(fragment['library']['id'])
        for case in requests['cases']:
            if case['id'] in case_ids:
                raise ValueError('Duplicate circuit identity across families.')
            case_ids.add(case['id'])
        total_cases += len(requests['cases'])
    if total_cases > 128:
        raise ValueError('Combined circuit count exceeds capture profile.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    snapshots = output / 'input-snapshots'
    snapshots.mkdir()
    shutil.copyfile(baseline_path, snapshots / 'baseline-manifest.json')
    here = Path(__file__).resolve()
    shutil.copyfile(here, snapshots / here.name)
    libraries = list(baseline['libraries'])
    cases = list(baseline['cases'])
    receipts, fragment_receipts = [], []
    family_matrix = {family: {'version': spec['version'], 'status': 'missing', 'caseIDs': []}
                     for family, spec in specifications.items()}
    bulk = next(library for library in libraries if library['id'] == specifications['BULK']['libraryID'])
    admission.check_library(specifications['BULK'], bulk)
    family_bindings = {'BULK': admission.binding(specifications['BULK'], bulk)}
    family_matrix['BULK'] = {'version': specifications['BULK']['version'], 'status': 'captured',
        'caseIDs': specifications['BULK']['requiredCaseIDs'], 'libraryID': bulk['id'], 'librarySHA256': bulk['sha256']}
    oracle = Path(baseline['oracle']['path'])
    for path, fragment_sha, fragment, requests, records in fragments:
        family = fragment['family']
        fragment_snapshot = snapshots / (family.lower() + '-fragment.json')
        shutil.copyfile(path, fragment_snapshot)
        provenance_snapshot = snapshots / (family.lower() + '-provenance.json')
        shutil.copyfile(fragment['provenanceReceipt']['path'], provenance_snapshot)
        requests_snapshot = snapshots / (family.lower() + '-requests.json')
        shutil.copyfile(fragment['requests']['path'], requests_snapshot)
        library = fragment['library']
        libraries.append(library)
        library_map = {library['id']: library}
        captured_ids = []
        for request in requests['cases']:
            command = tool.command(oracle, library_map, request)
            expected = request['expectedOutcome']
            raw = tool.run(command + ['--mode', 'solve'], output, 'solve-' + request['id'], receipts,
                           expected=0 if expected == 'converged' else 3)
            result = json.loads(raw)
            if result['status'] != expected:
                raise AssertionError(f'{request["id"]}: expected {expected}, got {result["status"]}')
            if any(dev['descriptorName'] != library['descriptorName'] for dev in result['devices']):
                raise AssertionError('Actual generated descriptor does not match the admitted fragment.')
            tool.check_analytic(request, result)
            if expected == 'converged':
                if any(row['normalizedResidual'] > 1 for row in result['unknowns']):
                    raise AssertionError('Completed independent result has unsatisfied physical equations.')
                validated = json.loads(tool.run(command + ['--mode', 'validate'] + tool.candidate_arguments(result),
                                               output, 'validate-' + request['id'], receipts))
                if validated['status'] != 'valid':
                    raise AssertionError('Independent result failed complete candidate re-evaluation.')
            cases.append({'id': request['id'], 'input': request, 'reference': result,
                          'validationBaseCommand': command + ['--mode', 'validate'], 'family': family})
            captured_ids.append(request['id'])
        family_bindings[family] = admission.binding(specifications[family], library)
        family_matrix[family] = {'version': fragment['version'], 'status': 'captured', 'caseIDs': captured_ids,
                                'libraryID': library['id'], 'librarySHA256': library['sha256']}
        fragment_receipts.append({'family': family, 'path': str(path), 'sha256': fragment_sha,
                                  'snapshotPath': str(fragment_snapshot),
                                  'provenanceSnapshotPath': str(provenance_snapshot),
                                  'requestsSnapshotPath': str(requests_snapshot)})
    if digest(baseline_path) != baseline_sha:
        raise RuntimeError('Baseline manifest changed during capture.')
    load_baseline(baseline_path)
    for path, expected, _, _, records in fragments:
        if digest(path) != expected:
            raise RuntimeError('A model fragment changed during capture.')
        for record in records:
            checked_file(record)
    complete = all(row['status'] == 'captured' for row in family_matrix.values())
    merged = dict(baseline)
    merged.update({'libraries': libraries, 'cases': cases, 'familyMatrix': family_matrix,
                   'familyBindings': family_bindings,
                   'qualificationProfile': {'id': args.profile, 'sha256': digest(admission.AUTHORITY)},
                   'qualificationComplete': complete, 'baselineManifest': {'path': str(baseline_path),
                       'sha256': baseline_sha, 'snapshotPath': str(snapshots / 'baseline-manifest.json')},
                   'modelFragments': fragment_receipts, 'captureTool': {'path': str(here),
                       'snapshotPath': str(snapshots / here.name), 'sha256': digest(here)},
                   'additionalCommands': receipts, 'additionalCaptureSeconds': time.monotonic() - started})
    admission.validate(merged, args.profile, complete=complete)
    shutil.copyfile(admission.AUTHORITY, snapshots / admission.AUTHORITY.name)
    shutil.copyfile(Path(admission.__file__), snapshots / 'family_profile.py')
    tool.save(output / 'manifest.json', merged)
    print(json.dumps({'manifest': str(output / 'manifest.json'), 'caseCount': len(cases),
                      'qualificationComplete': complete, 'familyMatrix': family_matrix,
                      'additionalCaptureSeconds': merged['additionalCaptureSeconds']}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=['historical-soi47-v1', 'latest-soi101-v1'], default=admission.DEFAULT_PROFILE)
    parser.add_argument('--oracle-manifest', type=Path, required=True)
    parser.add_argument('--fragment', type=Path, action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    capture(parser.parse_args())
