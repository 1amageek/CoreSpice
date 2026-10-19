#!/usr/bin/env python3
"""Derive a source-representable sweep using an admitted independent executable."""
from argparse import ArgumentParser
from pathlib import Path
import copy
import importlib.util
import json
import re
import shutil
import sys
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('dynamic', Path(__file__).with_name('dynamic.py'))
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)
FREQUENCIES = [1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9]


def derive(args):
    D.guard();started = time.monotonic()
    parent_record = {'path': str(args.manifest.resolve()), 'sha256': args.manifest_sha256}
    D.FAMILIES.checked_file(parent_record)
    parent = D.read_analysis_json(args.manifest)
    if parent['schema'] != 'corespice.osdi.analysis-manifest.v1' or parent['status'] != 'passed':
        raise ValueError('A completed independent analysis capture is required.')
    if parent['headerSHA256'] != D.BASE.HEADER_SHA or parent['compilerProfileReceiptSHA256'] != D.BASE.PROFILE_RECEIPT_SHA:
        raise ValueError('The pinned ABI/compiler profile is required.')
    for row in [parent['oracle'], parent['compiler'], *parent['libraries']]:
        D.FAMILIES.checked_file(row)
    for row in parent['sources']:
        D.FAMILIES.checked_file({'path': row['snapshotPath'], 'sha256': row['sha256']})
    accuracy = D.read_analysis_json(args.time_accuracy_receipt)
    admitted_accuracy = parent.get('derivedFrom', {}).get('timeAccuracyReceipt', {})
    if accuracy['status'] != 'passed' or (accuracy['manifestSHA256'] != args.manifest_sha256
            and admitted_accuracy.get('sha256') != D.BASE.digest(args.time_accuracy_receipt)):
        raise ValueError('Time-accuracy evidence must belong to the unchanged parent capture.')
    output = args.output.resolve();output.mkdir(parents=True, exist_ok=False)
    snapshots = output / 'input-snapshots';snapshots.mkdir()
    shutil.copyfile(args.manifest, snapshots / 'parent-manifest.json')
    result = copy.deepcopy(parent);commands = [];changes = [];endpoint_changes = []
    libraries = {row['id']: row for row in parent['libraries']}
    for case, original in zip(result['cases'], parent['cases'], strict=True):
        regenerate = False
        if args.transient_stop_policy == 'preserve' and case['kind'] in ('ac', 'noise'):
            before = case['input']['analysis']['frequenciesHz']
            changes.append({'caseID': case['id'], 'beforeHz': before, 'afterHz': FREQUENCIES})
            case['input']['analysis']['frequenciesHz'] = FREQUENCIES
            regenerate = True
        elif args.transient_stop_policy == 'last-pwl-knot' and case['kind'] == 'transient' and case['family']:
            config = case['input']['analysis'];last = config['steps'][-1]
            target = config['stimulus']['points'][-1]['timeSeconds']
            previous = config['steps'][-2]['timeSeconds'] if len(config['steps']) > 1 else 0.
            if not previous < target:
                raise ValueError('Selected endpoint must follow the preceding accepted sample.')
            endpoint_changes.append({'caseID': case['id'], 'beforeStopSeconds': last['timeSeconds'],
                                     'beforeStepSeconds': last['timeStepSeconds'], 'afterStopSeconds': target,
                                     'afterStepSeconds': target - previous})
            last['timeSeconds'] = target;last['timeStepSeconds'] = target - previous
            regenerate = True
        if regenerate:
            command = D.dynamic_command(parent['oracle']['path'], libraries, case['input'])
            if case['expectedOutcome'] == 'invalidSourcePSD':
                D.run(command, output, case['id'], commands, expected=2)
                diagnostic = (output / (case['id'] + '.stderr')).read_text()
                match = re.search(r'device=(\S+) sourceIndex=(\d+) name=(\S+) frequency=(\S+) density=(\S+)', diagnostic)
                if not match or 'invalid source PSD' not in diagnostic or float(match[5]) >= 0:
                    raise ValueError('Expected an identified unchanged negative source PSD.')
                failure = {'stage': 'noise', 'reason': 'invalid_source_psd', 'deviceID': match[1],
                           'sourceIndex': int(match[2]), 'sourceName': match[3],
                           'frequencyHz': float(match[4]), 'rawDensity': float(match[5])}
                case['reference'] = {'schema': 'corespice.osdi.analysis-result.v1', 'kind': case['kind'],
                                     'status': 'expectedFailure', 'failure': failure}
            else:
                case['reference'] = json.loads(D.run(command, output, case['id'], commands))
                if case['reference']['status'] != 'passed':
                    raise ValueError('Independent physical evaluation failed: ' + case['id'])
            case['oracleBaseCommand'] = command
        else:
            assert case['input'] == original['input'] and case['reference'] == original['reference']
        case['validationBaseCommand'] = [sys.executable, str(D.HERE / 'dynamic.py'), 'validate',
                                         '--manifest', str(output / 'manifest.json'), '--case-id', case['id']]
    result['analyticChecks'] = D.analytic_checks(result['cases'])
    result['derivedFrom'] = {'manifest': parent_record, 'priorDerivation': parent.get('derivedFrom'),
                             'sourceSweep': 'dec 1 1k 1G', 'frequencyChanges': changes,
                             'transientStopPolicy': args.transient_stop_policy, 'endpointChanges': endpoint_changes,
                             'transientInputsAndReferencesUnchanged': not endpoint_changes}
    accuracy_record = {'path': str(args.time_accuracy_receipt.resolve()), 'sha256': D.BASE.digest(args.time_accuracy_receipt)}
    if endpoint_changes:
        result['derivedFrom']['priorTimeAccuracyReceipt'] = accuracy_record
        result['derivedFrom']['timeAccuracyCasesRequiringRefresh'] = [c['caseID'] for c in endpoint_changes]
    else:
        result['derivedFrom']['timeAccuracyReceipt'] = accuracy_record
    for path in (Path(__file__).resolve(), D.HERE / 'dynamic.py'):
        sha = D.BASE.digest(path);destination = snapshots / (path.stem + '-' + sha[:12] + path.suffix)
        shutil.copyfile(path, destination)
        result['sources'].append({'name': path.name, 'sourcePath': str(path),
                                  'snapshotPath': str(destination), 'sha256': sha})
    result['commands'] = commands;result['seconds'] = time.monotonic() - started
    D.BASE.save(snapshots / 'requests.json', {'schema': 'corespice.osdi.analysis-inputs.v1',
                                            'cases': [{'id': c['id'], 'input': c['input']} for c in result['cases']]})
    for row in [parent_record, parent['oracle'], parent['compiler'], *parent['libraries']]:
        D.FAMILIES.checked_file(row)
    for row in result['sources']:
        D.FAMILIES.checked_file({'path': row['snapshotPath'], 'sha256': row['sha256']})
    for row in result['sources'][-2:]:
        assert D.BASE.digest(row['sourcePath']) == row['sha256']
    D.BASE.save(output / 'manifest.json', result)
    print(json.dumps({'manifest': str(output / 'manifest.json'), 'sha256': D.BASE.digest(output / 'manifest.json'),
                      'cases': len(result['cases']), 'frequencyCases': len(changes),
                      'endpointCases': len(endpoint_changes), 'seconds': result['seconds']}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--time-accuracy-receipt', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--transient-stop-policy', choices=('preserve', 'last-pwl-knot'), default='preserve')
    derive(parser.parse_args())
