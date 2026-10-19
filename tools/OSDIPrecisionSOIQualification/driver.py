#!/usr/bin/env python3
"""Freeze and independently replay latest SOI 101 compensated circuit witnesses."""
if not __debug__:
    raise RuntimeError('SOI circuit qualification requires assertion-enabled Python')

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OSDI_COMMIT = '9e321b082d71528b64c7ca69d640389c0e144cbb'
SOURCE_SHA = 'cba0d2de068e86b026d9580c9d8ab78f592ccc3d9dc8efb98fb5d67182be0a87'
BASE_REQUEST_SHA = '2e04e9b4ca3fca95cd60da6eec48aa3c6e4c79f7beb421d3bcfac3b7b130c80e'
ANALYSIS_MANIFEST_SHA = '569a695ffd173701bfb840316053e4ef6436782eebedb4a35ee0870ba6c4e3b7'
CASE_IDS = tuple('soi101-' + polarity + '-' + mode for polarity in ('n', 'p') for mode in ('pd', 'dd'))


def require(value, reason):
    if not value:
        raise ValueError(reason)


def identity(path, expected=None):
    path = Path(path).resolve(strict=True)
    require(path.is_file() and path.stat().st_size <= 256 * 1024 * 1024, 'input_size_or_type:' + str(path))
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(65536):
            digest.update(chunk)
    result = {'path': str(path), 'sha256': digest.hexdigest(), 'byteCount': path.stat().st_size}
    require(expected is None or result['sha256'] == expected, 'input_identity:' + str(path))
    return result


def read(path):
    require(Path(path).stat().st_size <= 32 * 1024 * 1024, 'json_input_size')
    return json.loads(Path(path).read_text())


def fact(value):
    item = identity(value['path'], value['sha256'])
    require(item['byteCount'] == value.get('byteCount', value.get('bytes', item['byteCount'])), 'input_byte_count')
    return item


def save(path, value):
    with Path(path).open('x') as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write('\n')


def prepare(args):
    base_fact = identity(args.base_request)
    analysis_fact = identity(args.analysis_manifest)
    require(base_fact['sha256'] == BASE_REQUEST_SHA, 'original_base_request_identity')
    require(analysis_fact['sha256'] == ANALYSIS_MANIFEST_SHA, 'original_analysis_manifest_identity')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    qualified = read(args.qualification)
    require(qualified.get('passed') is True and qualified.get('schema') == 'osdi.soi101.precision-qualified.v2', 'soi_qualification')
    source, model = fact(qualified['source']), fact(qualified['model'])
    compilation = read(fact(qualified['compileReceipt'])['path'])
    compiler = fact(qualified['compiler'])
    fact(qualified['acquisition'])
    semantic_fact = fact(qualified['semanticProfile'])
    require(compilation.get('exitCode') == 0 and compilation['sourceSHA256'] == source['sha256']
            and compilation['compilerSHA256'] == compiler['sha256']
            and compilation['imageSHA256'] == model['sha256']
            and compilation['semanticProfileSHA256'] == semantic_fact['sha256'], 'source_compiler_model_binding')
    require(source['sha256'] == SOURCE_SHA, 'official_soi101_source')
    require({case['id'] for case in qualified['cases']} == set(CASE_IDS), 'four_polarity_mode_selectors')
    verification_fact = fact(qualified['modelVerification'])
    verified = read(verification_fact['path'])
    require(verified.get('succeeded') is True, 'point_program_verification')
    requests = {}
    for case in qualified['cases']:
        record = fact(case['request'])
        fact(case['report'])
        request = read(record['path'])
        require(request['model']['expectedSHA256'] == model['sha256'], 'point_model_binding')
        requests[case['id']] = request
    first = requests[CASE_IDS[0]]
    semantic = first['semanticProfileSHA256']
    require(semantic == semantic_fact['sha256'], 'request_semantic_binding')
    programs = [identity(verified['families'][name]['programPath'], verified['families'][name]['programSHA256']) for name in CASE_IDS]
    require(len({item['sha256'] for item in programs}) == 1, 'single_source_program')
    for name in CASE_IDS:
        require(requests[name]['semanticProfileSHA256'] == semantic, 'semantic_profile')
        params = {item['name']: item['value'] for item in requests[name]['model']['parameters']}
        require(params['TYPE']['integer'] == (1 if '-n-' in name else -1), 'polarity_binding')
        require(params['SOIMOD']['integer'] == (0 if name.endswith('-pd') else 1), 'soi_mode_binding')
    worker_build = read(args.worker_receipt)
    worker = fact(worker_build['worker'])
    numeric = fact(worker_build['numericProfile'])
    numeric_profile = read(numeric['path'])
    require(numeric_profile['worker']['sha256'] == worker['sha256'], 'numeric_profile_worker_binding')
    if 'semanticProfileSHA256' in numeric_profile:
        require(numeric_profile['semanticProfileSHA256'] == semantic, 'numeric_profile_semantic_binding')
    osdi_root = args.osdi_root.resolve(strict=True)
    commit = subprocess.check_output(['git', '-C', str(osdi_root), 'rev-parse', 'HEAD'], text=True, timeout=10).strip()
    require(commit == OSDI_COMMIT, 'released_osdi_commit')
    recorded = {}
    for item in worker_build['sources']:
        actual = fact(item)
        path = Path(actual['path'])
        marker = '/Sources/'
        if marker in str(path):
            relative = 'Sources/' + str(path).split(marker, 1)[1]
            tracked = subprocess.check_output(['git', '-C', str(osdi_root), 'show', OSDI_COMMIT + ':' + relative], timeout=10)
            require(hashlib.sha256(tracked).hexdigest() == actual['sha256'], 'worker_source_not_released:' + relative)
            recorded[relative] = actual['sha256']
    required = list((osdi_root / 'Sources/COSDIPrecision').rglob('*.c')) + [osdi_root / 'Sources/OSDIPrecisionWorker/WorkerEntry.c']
    require(all(str(path.relative_to(osdi_root)) in recorded for path in required), 'worker_source_coverage')
    require({item['path']: item['sha256'] for item in numeric_profile['sources']} == recorded,
            'numeric_profile_source_binding')
    base = read(args.base_request)['circuit']
    analysis = next(case['input']['analysis'] for case in read(args.analysis_manifest)['cases'] if case['kind'] == 'transient')
    require(base['policy']['equationAbsoluteTolerances'] == {'A': 1e-12, 'V': 1e-10, 'W': 1e-12}, 'original_equation_policy')
    require(len(base['devices']) == 1 and base['devices'][0]['connectedTerminalCount'] == 6, 'original_six_terminal_circuit')
    require(analysis['steps'][0]['timeStepSeconds'] == 1e-10 and analysis['steps'][-1]['timeSeconds'] == 2e-9, 'full_original_schedule')
    parameters = {item['name']: item['value'] for item in base['devices'][0]['parameters']}
    require(parameters['TYPE']['integer'] == 1 and parameters['SOIMOD']['integer'] == 1
            and parameters['SHMOD']['integer'] == 0, 'original_n_dd_nonthermal_setup')
    cases = []
    for name in CASE_IDS:
        circuit, schedule = copy.deepcopy(base), copy.deepcopy(analysis)
        sign = 1 if '-n-' in name else -1
        device = circuit['devices'][0]
        for parameter in device['parameters']:
            if parameter['name'] == 'TYPE':
                parameter['value']['integer'] = sign
            if parameter['name'] == 'SOIMOD':
                parameter['value']['integer'] = 0 if name.endswith('-pd') else 1
        for part in circuit['voltageSources'] + circuit['currentSources']:
            part['value'] *= sign
        circuit['initialUnknowns'] = {key: sign * value for key, value in circuit['initialUnknowns'].items()}
        for knot in schedule['stimulus']['points']:
            knot['value'] *= sign
        case_id = name + '-transient'
        circuit['id'] = case_id
        directory = output / case_id
        directory.mkdir()
        deck = directory / 'input.cir'
        lines = [case_id, '.model M1 osdi', 'N_M1 d g 0 0 0 0 M1']
        for part in circuit['resistors']:
            lines.append(f'{part["id"]} {part["positive"]} {part["negative"]} {part["value"]}')
        for part in circuit['voltageSources'] + circuit['currentSources']:
            value = str(part['value'])
            if part['id'] == schedule['stimulus']['sourceID']:
                value = 'PWL(' + ' '.join(f'{p["timeSeconds"]} {p["value"]}' for p in schedule['stimulus']['points']) + ')'
            lines.append(f'{part["id"]} {part["positive"]} {part["negative"]} {value}')
        policy = circuit['policy']
        lines.append(f'.options temp={device["temperatureKelvin"] - 273.15} tnom=27 gmin=0 reltol={policy["relativeTolerance"]} abstol=1e-12 vntol=1e-10 itl1={policy["maximumIterations"]} tranmaxaccepted=1000 tranmaxattempts=10000 tranmaxiterations=100000 tranmaxscalars=100000 tranmaxdimension=256 tranmaxwork=1000000000 tranmaxbreakpoints=100')
        for key, value in sorted(circuit['initialUnknowns'].items()):
            require(key.startswith('net:'), 'source_initial_unknown')
            lines.append(f'.nodeset V({key[4:]})={value}')
        lines += ['.tran 1e-10 2e-9 0 1e-10', '.end', '']
        deck.write_text('\n'.join(lines))
        cases.append({'id': case_id, 'kind': 'transient', 'input': {'circuit': circuit, 'analysis': schedule},
                      'directory': str(directory), 'deck': identity(deck)})
    precision = {'schema': 'corespice.osdi.precision-manifest.v1', 'worker': worker,
                 'semanticProfileSHA256': semantic, 'numericProfileSHA256': numeric['sha256'],
                 'precisionBits': first['precisionBits'], 'options': first['options'],
                 'models': [{'id': 'soi101', **model, 'descriptorIndex': 0, 'descriptorName': 'bsimsoi',
                             'program': programs[0], 'source': source}],
                 'qualification': identity(args.qualification), 'workerBuild': identity(args.worker_receipt),
                 'releasedOSDICommit': commit}
    save(output / 'precision-manifest.json', precision)
    save(output / 'analysis-manifest.json', {'schema': 'corespice.soi101.precision-inputs.v1', 'cases': cases})
    inputs = {'schema': 'corespice.soi101.precision-qualification.v1', 'precisionManifest': str(output / 'precision-manifest.json'),
              'precisionManifestIdentity': identity(output / 'precision-manifest.json'),
              'cases': cases, 'provenance': [base_fact, analysis_fact, identity(__file__)]}
    save(output / 'inputs.json', inputs)
    print(json.dumps({'inputs': str(output / 'inputs.json'), 'caseIDs': [case['id'] for case in cases]}))


def replay(args):
    inputs = read(args.inputs)
    require(inputs.get('schema') == 'corespice.soi101.precision-qualification.v1', 'qualification_inputs_schema')
    fact(inputs['precisionManifestIdentity'])
    require({case['id'] for case in inputs['cases']} == {name + '-transient' for name in CASE_IDS}, 'mandatory_case_set')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    checks = []
    receipt = {'schema': 'corespice.soi101.precision-replay.v1', 'status': 'failed', 'checks': checks,
               'inputs': identity(args.inputs), 'oracleBuild': identity(args.oracle_build)}
    try:
        for case in inputs['cases']:
            fact(case['deck'])
            directory = Path(case['directory'])
            artifacts = [directory / (lane + '.json') for lane in ('api', 'batch', 'prepared')]
            records = [read(path) for path in artifacts]
            # Strict lane equality is checked by the Swift JSON/CSV decoders too.
            executions = [record['osdiExecution'] for record in records]
            require(all(value == executions[0] for value in executions[1:]), 'lane_candidate_disagreement:' + case['id'])
            argv = [sys.executable, str(ROOT / 'tools/OSDIDCVerification/Precision/replay_artifact.py'),
                    '--artifact', str(artifacts[0]), '--precision-manifest', inputs['precisionManifest'],
                    '--oracle-build', str(args.oracle_build), '--analysis-manifest', str(Path(args.inputs).parent / 'analysis-manifest.json'),
                    '--case-id', case['id'], '--output', str(output / case['id']), '--timeout-seconds', str(args.timeout)]
            started = time.monotonic()
            child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                stdout, stderr = child.communicate(timeout=args.timeout + 10)
            except BaseException:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.communicate(timeout=5)
                raise
            (output / (case['id'] + '.stdout')).write_text(stdout)
            (output / (case['id'] + '.stderr')).write_text(stderr)
            require(child.returncode == 0, 'independent_replay_failed:' + case['id'] + ':' + stderr)
            result = read(output / case['id'] / 'receipt.json')
            require(result['status'] == 'passed', 'independent_receipt_failed')
            checks.append({'caseID': case['id'], 'lanes': [identity(path) for path in artifacts],
                           'replay': identity(output / case['id'] / 'receipt.json'), 'command': argv,
                           'seconds': time.monotonic() - started, 'exitCode': child.returncode})
        require(len(checks) == 4, 'four_case_coverage')
        receipt['status'] = 'passed'
    finally:
        save(output / 'receipt.json', receipt)
    print(json.dumps({'status': 'passed', 'receipt': str(output / 'receipt.json')}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare_parser = commands.add_parser('prepare')
    for name in ('qualification', 'base-request', 'analysis-manifest', 'worker-receipt', 'osdi-root', 'output'):
        prepare_parser.add_argument('--' + name, required=True, type=Path)
    replay_parser = commands.add_parser('replay')
    for name in ('inputs', 'oracle-build', 'output'):
        replay_parser.add_argument('--' + name, required=True, type=Path)
    replay_parser.add_argument('--timeout', type=int, default=660)
    args = parser.parse_args()
    if args.command == 'replay':
        require(0 < args.timeout <= 3600, 'positive_bounded_timeout')
        replay(args)
    else:
        prepare(args)


if __name__ == '__main__':
    main()
