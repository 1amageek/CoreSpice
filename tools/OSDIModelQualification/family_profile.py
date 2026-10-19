#!/usr/bin/env python3
"""Admit finite family captures against the tracked source/request authority."""
from hashlib import sha256
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]
AUTHORITY = Path(__file__).with_name('profiles.json')
DEFAULT_PROFILE = 'latest-soi101-v1'


def digest(path):
    return sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    path = Path(path)
    if path.stat().st_size > 1024 * 1024:
        raise ValueError('Profile JSON exceeds its one-MiB bound.')
    def reject(value):
        raise ValueError('Nonfinite profile JSON: ' + value)
    return json.loads(path.read_text(), parse_constant=reject)


def load(identifier):
    authority = read(AUTHORITY)
    if authority['schema'] != 'corespice.osdi.family-profile-authority.v1':
        raise ValueError('Unsupported family authority schema.')
    selected = authority['profiles'].get(identifier)
    if selected is None or set(selected) != {'BULK', 'CMG', 'IMG', 'SOI'}:
        raise ValueError('An explicit supported four-family profile is required.')
    families = {name: authority['families'][key] for name, key in selected.items()}
    baseline_path = ROOT / authority['baselineRequestPath']
    if digest(baseline_path) != authority['baselineRequestSHA256']:
        raise ValueError('Tracked baseline requests changed without profile review.')
    baseline = read(baseline_path)['cases']
    if [case['id'] for case in baseline] != authority['requiredBaselineCaseIDs']:
        raise ValueError('Required baseline case identities changed.')
    requests = {}
    for name, family in families.items():
        path = ROOT / family['requestPath']
        if family['family'] != name or digest(path) != family['requestSHA256']:
            raise ValueError('Tracked family request/source authority mismatch.')
        by_id = unique(read(path)['cases'], 'request')
        required = family['requiredCaseIDs']
        if len(required) != len(set(required)) or not set(required) <= set(by_id):
            raise ValueError('Required family case identities are invalid.')
        requests[name] = {key: by_id[key] for key in required}
    return families, requests, baseline


def unique(values, label):
    result = {}
    for value in values:
        identifier = value['id']
        if identifier in result:
            raise ValueError('Duplicate ' + label + ' identity: ' + identifier)
        result[identifier] = value
    return result


def binding(specification, library):
    return {'version': specification['version'], 'library': dict(library),
            'sourceSHA256': specification['sourceSHA256'],
            'compilerSHA256': specification['compilerSHA256'],
            'compilerProfileReceiptSHA256': specification['compilerProfileReceiptSHA256'],
            'requestSHA256': specification['requestSHA256']}


def check_library(specification, library):
    for expected, actual in [('libraryID', 'id'), ('descriptorIndex', 'descriptorIndex'),
                             ('descriptorName', 'descriptorName')]:
        if type(library[actual]) is not type(specification[expected]) or library[actual] != specification[expected]:
            raise ValueError('Family library/descriptor binding mismatch.')
    identity = library['sha256']
    if (not isinstance(identity, str) or len(identity) != 64
            or any(value not in '0123456789abcdef' for value in identity)
            or identity != specification['artifactSHA256']):
        raise ValueError('Family artifact identity mismatch.')


def validate(manifest, identifier=DEFAULT_PROFILE, complete=True):
    families, requests, baseline = load(identifier)
    if manifest['schema'] != 'corespice.osdi.dc-manifest.v1' or manifest['status'] != 'passed':
        raise ValueError('A passed independent DC capture is required.')
    if manifest.get('qualificationProfile') != {'id': identifier, 'sha256': digest(AUTHORITY)}:
        raise ValueError('Missing or stale qualification profile authority.')
    libraries = unique(manifest['libraries'], 'library')
    cases = unique(manifest['cases'], 'case')
    bindings = manifest.get('familyBindings', {})
    if not set(bindings) <= set(families) or 'BULK' not in bindings:
        raise ValueError('Unknown or missing baseline family binding.')
    if complete and set(bindings) != set(families):
        raise ValueError('A required model family is missing.')
    expected_ids = {case['id'] for case in baseline}
    for case in baseline:
        if case['id'] not in cases or cases[case['id']]['input'] != case:
            raise ValueError('A required analytic/BULK baseline request is missing or changed.')
    expected_matrix = {}
    for family, specification in families.items():
        captured = family in bindings
        ids = specification['requiredCaseIDs'] if captured else []
        row = {'version': specification['version'], 'status': 'captured' if captured else 'missing',
               'caseIDs': ids}
        if captured:
            record = bindings[family]
            library = libraries.get(specification['libraryID'])
            if library is None:
                raise ValueError('A required family library is missing.')
            check_library(specification, library)
            if record != binding(specification, library):
                raise ValueError('Family version/source/compiler/request/library binding mismatch.')
            row['libraryID'] = library['id']
            row['librarySHA256'] = library['sha256']
            for identifier_, request in requests[family].items():
                expected_ids.add(identifier_)
                captured_case = cases.get(identifier_)
                if captured_case is None or captured_case['input'] != request:
                    raise ValueError('A required family request is missing or changed.')
                if family != 'BULK' and captured_case.get('family') != family:
                    raise ValueError('A required case is assigned to the wrong family.')
                if any(device['library'] != library['id'] or device['descriptorIndex'] != library['descriptorIndex']
                       for device in request['devices']):
                    raise ValueError('Required case binds a different family descriptor.')
                if captured_case['reference']['status'] != request['expectedOutcome']:
                    raise ValueError('Required case did not reach its expected independent outcome.')
        expected_matrix[family] = row
    if set(cases) != expected_ids:
        raise ValueError('Unexpected or omitted case outside the selected finite profile.')
    if manifest.get('familyMatrix') != expected_matrix:
        raise ValueError('Family matrix does not describe the actual admitted cases and libraries.')
    if manifest.get('qualificationComplete') is not (set(bindings) == set(families)):
        raise ValueError('Qualification completeness does not match admitted families.')
    return expected_matrix
