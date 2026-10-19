#!/usr/bin/env python3
"""Build/capture the independent dynamic ABI oracle, or replay a complete candidate."""
from argparse import ArgumentParser
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import copy
import importlib.util
import json
import math
import re
import shutil
import sys
import time


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(value)
    finally:
        sys.dont_write_bytecode = previous
    return value


HERE = Path(__file__).resolve().parent
BASE = module(HERE.parent / 'OSDIDCVerification' / 'build.py', 'independent_dc')
FAMILIES = module(HERE / 'capture.py', 'model_capture')
VALIDATION_RECEIPT_BYTES = 8 * 1024 * 1024
VALIDATION_RESERVE_BYTES = 32 * 1024 * 1024
SIGNED_NOISE_CASE_IDS = frozenset((
    'bsim-p-reverse-loaded-s4-noise', 'cmg-p-reverse-loaded-s4-noise',
    'img-p-reverse-s4-noise', 'soi-p-reverse-s4-noise'))


class ValidationResourceFailure(RuntimeError):
    def __init__(self, reason):
        self.reason = reason
        super().__init__('Validation resource failure: ' + reason)


def validation_profile(destination, candidate_file_bytes=BASE.MAX_INPUT_BYTES):
    if candidate_file_bytes not in (BASE.MAX_INPUT_BYTES, 8 * 1024 * 1024):
        raise ValidationResourceFailure('unsupported_candidate_capacity_profile')
    reserve = VALIDATION_RESERVE_BYTES if candidate_file_bytes == BASE.MAX_INPUT_BYTES else 64 * 1024 * 1024
    existing = destination
    while not existing.exists():
        existing = existing.parent
    free = shutil.disk_usage(existing).free
    if free < reserve:
        raise ValidationResourceFailure('insufficient_output_space')
    return {'name': 'existing-image-validation-v1' if candidate_file_bytes == BASE.MAX_INPUT_BYTES else 'existing-image-validation-1000-v1',
            'minimumFreeBytes': reserve, 'observedFreeBytes': free, 'candidateFileLimitBytes': candidate_file_bytes,
            'candidateFileCount': 2, 'childLogLimitBytes': BASE.MAX_OUTPUT_BYTES,
            'childLogCount': 2, 'receiptLimitBytes': VALIDATION_RECEIPT_BYTES}


def bounded_candidate(path, lines, byte_limit=BASE.MAX_INPUT_BYTES):
    count = 0
    with path.open('xb') as stream:
        for line in lines:
            data = line.encode()
            if count + len(data) > byte_limit:
                raise ValidationResourceFailure('candidate_output_limit')
            stream.write(data);count += len(data)


def validation_receipt(output, value):
    data = (json.dumps(value, indent=2, allow_nan=False) + '\n').encode()
    if len(data) > VALIDATION_RECEIPT_BYTES:
        raise ValidationResourceFailure('receipt_output_limit')
    temporary = output / 'receipt.partial'
    with temporary.open('xb') as stream:
        stream.write(data)
    temporary.replace(output / 'receipt.json')


def read_analysis_json(path):
    path = Path(path)
    if path.stat().st_size > 8 * 1024 * 1024:
        raise ValueError('Dynamic manifest/candidate JSON exceeds eight MiB.')
    def reject(value):
        raise ValueError('Nonfinite JSON token: ' + value)
    return json.loads(path.read_text(), parse_constant=reject)


def guard():
    if shutil.disk_usage(HERE).free <= 2 * 1024**3:
        raise RuntimeError('Independent execution requires more than two GiB free disk.')


def run(argv, output, label, receipts, expected=0):
    guard()
    return BASE.run(argv, output, label, receipts, expected=expected)


def dynamic_command(oracle, libraries, request):
    args = BASE.command(oracle, libraries, request['circuit'])
    config = request['analysis']
    kind = config['kind']
    args += ['--analysis', kind]
    if kind in ('ac', 'noise'):
        for frequency in config['frequenciesHz']:
            args += ['--frequency', repr(frequency)]
    if kind == 'ac':
        stimulus = config['stimulus']
        args += ['--stimulus', stimulus['sourceID'], repr(stimulus['real']), repr(stimulus['imag'])]
    elif kind == 'noise':
        args += ['--stimulus', config['inputSourceID'], '1', '0', '--noise-temperature',
                 repr(config['resistorTemperatureKelvin']), '--output', config['output']['positiveUnknownID'],
                 config['output'].get('negativeUnknownID') or '0']
    else:
        args += ['--initialize', config['initialization']]
        for key, value in config.get('uicInitialUnknowns', {}).items():
            args += ['--uic', key, repr(value)]
        stimulus = config['stimulus']
        for knot in stimulus['points']:
            args += ['--waveform', stimulus['sourceID'], repr(knot['timeSeconds']), repr(knot['value'])]
        for step in config['steps']:
            args += ['--step', repr(step['timeSeconds']), repr(step['timeStepSeconds']), step['method']]
        if 'forcedRejectedTrialIndex' in config:
            args += ['--force-reject', str(config['forcedRejectedTrialIndex'])]
    return args


def source(identifier, positive, negative, value):
    return {'id': identifier, 'positive': positive, 'negative': negative, 'value': value}


def analytic_circuit(library, parameters=None, terminals=None):
    return {'id': library, 'devices': [{'id': 'N1', 'library': library, 'descriptorIndex': 0,
            'temperatureKelvin': 300.15, 'connectedTerminalCount': len(terminals or {'p': 'p', 'n': '0'}),
            'terminals': terminals or {'p': 'p', 'n': '0'}, 'parameters': parameters or [], 'previousState': []}],
            'resistors': [source('RLOAD', 'supply', 'p', 1000.)],
            'voltageSources': [source('VIN', 'supply', '0', 1.)], 'currentSources': [],
            'initialUnknowns': {}, 'expectedOutcome': 'converged', 'analyticUnknowns': {},
            'policy': {'unknownAbsoluteTolerances': {'V': 1e-9, 'A': 1e-12, 'K': 1e-7},
                       'equationAbsoluteTolerances': {'A': 1e-12, 'V': 1e-10, 'W': 1e-12},
                       'relativeTolerance': 1e-10, 'maximumIterations': 80, 'maximumBacktracks': 24}}


def parameter(name, value, kind='real'):
    return {'name': name, 'scope': 'model', 'value': {'kind': kind, kind: value}}


def schedule(h, count=12, trap=True):
    return [{'timeSeconds': (i + 1) * h, 'timeStepSeconds': h,
             'method': 'trapezoidal' if trap and i >= 3 else 'backwardEuler'} for i in range(count)]


def frequency_analysis(kind, source_id, output='net:p', temperature=300.15):
    value = {'kind': kind, 'frequenciesHz': [1e3, 1e6, 1e9]}
    if kind == 'ac':
        value['stimulus'] = {'sourceID': source_id, 'real': 1., 'imag': .5}
    else:
        value.update(output={'positiveUnknownID': output, 'negativeUnknownID': None},
                     inputSourceID=source_id, resistorTemperatureKelvin=temperature)
    return value


def make_requests(baseline):
    cases = []
    def add(identifier, circuit, analysis, family=None):
        cases.append({'id': identifier, 'kind': analysis['kind'], 'family': family,
                      'input': {'circuit': copy.deepcopy(circuit), 'analysis': analysis}})
    rc = analytic_circuit('dynamic_rc')
    for kind in ('ac', 'noise'):
        add('analytic-rc-' + kind, rc, frequency_analysis(kind, 'VIN'))
    current_noise = copy.deepcopy(rc)
    current_noise['currentSources'].append(source('IIN', '0', 'p', 0.))
    add('analytic-rc-current-noise', current_noise, frequency_analysis('noise', 'IIN'))
    ctx = analytic_circuit('dynamic_context')
    for kind in ('ac', 'noise'):
        add('analytic-context-' + kind, ctx, frequency_analysis(kind, 'VIN'))
    flow = analytic_circuit('dynamic_flow_thermal')
    add('analytic-flow-thermal-ac', flow, frequency_analysis('ac', 'VIN'))
    # The non-ground UIC has a literal 0.5 V terminal difference and no manufactured OP.
    for nonlinear in (False, True):
        q = analytic_circuit('dynamic_rc', [parameter('q3', 2e-9 if nonlinear else 0)], {'p': 'p', 'n': 'n'})
        q['resistors'] = []
        q['voltageSources'] = [source('VREF', 'n', '0', .2)]
        q['currentSources'] = [source('IIN', '0', 'p', 0.)]
        analysis = {'kind': 'transient', 'initialization': 'uic',
                    'uicInitialUnknowns': {'net:p': .7, 'net:n': .2},
                    'stimulus': {'sourceID': 'IIN', 'points': [{'timeSeconds': 0., 'value': 0.}]},
                    'steps': schedule(2e-8)}
        add('analytic-nonlinear-q' if nonlinear else 'analytic-uic-rc', q, analysis)
    latch = analytic_circuit('dynamic_latch', terminals={'d': 'drive', 'q': 'p'})
    latch['resistors'] = []
    latch['voltageSources'] = [source('VIN', 'drive', '0', 0.)]
    latch['devices'][0]['previousState'] = [0.]
    analysis = {'kind': 'transient', 'initialization': 'uic', 'uicInitialUnknowns': {},
                'stimulus': {'sourceID': 'VIN', 'points': [{'timeSeconds': 0., 'value': 0.},
                    {'timeSeconds': 1e-9, 'value': 1.}, {'timeSeconds': 2e-9, 'value': .5},
                    {'timeSeconds': 3e-9, 'value': 0.}, {'timeSeconds': 4e-9, 'value': .5}]},
                'steps': schedule(1e-9, 4, False), 'forcedRejectedTrialIndex': 1}
    add('analytic-retained-state', latch, analysis)
    state = analytic_circuit('state2', terminals={'p': 'p'})
    state['devices'][0]['previousState'] = [0., 37.]
    state['resistors'] = [];state['voltageSources'] = []
    state['currentSources'] = [source('IIN', '0', 'p', 1.)]
    add('analytic-two-slot-state', state, {'kind': 'transient', 'initialization': 'uic', 'uicInitialUnknowns': {},
        'stimulus': {'sourceID': 'IIN', 'points': [{'timeSeconds': 0., 'value': 1.}]},
        'steps': schedule(1e-9, 3, False), 'forcedRejectedTrialIndex': 1})
    selected = {'BULK': ['bsim-n-loaded', 'bsim-p-reverse-loaded', 'bsim-p-selfheat-loaded'],
                'CMG': ['cmg-n-loaded', 'cmg-p-reverse-loaded', 'cmg-n-selfheat-series-loaded'],
                'IMG': ['img-n-loaded', 'img-p-reverse', 'img-n-thermal'],
                'SOI': ['soi-n-forward', 'soi-p-reverse', 'soi-n-series-thermal']}
    for family, identifiers in selected.items():
        for index, identifier in enumerate(identifiers):
            circuit = copy.deepcopy(next(c['input'] for c in baseline['cases'] if c['id'] == identifier))
            dev = circuit['devices'][0]
            # S3 clamped-bias probes become explicitly loaded S4 amplifier circuits.
            drain_source = next((v for v in circuit['voltageSources'] if v['positive'] == 'd' and v['negative'] == '0'), None)
            if drain_source is not None:
                drain_source['positive'] = 'supply'
                circuit['resistors'].append(source('RLOAD', 'supply', 'd', 1000.))
                circuit['initialUnknowns']['net:supply'] = drain_source['value']
            if index == 2:
                # These are explicit selectors of unchanged official model code.
                spelling = 'tnoimod' if family == 'CMG' else 'TNOIMOD'
                dev['parameters'] = [p for p in dev['parameters'] if p['name'].lower() != 'tnoimod']
                dev['parameters'].append(parameter(spelling, 3 if family == 'SOI' else 1, 'integer'))
            gate = next(name for name in dev['terminals'] if name.lower() in ('g', 'fg'))
            gate_net = dev['terminals'][gate]
            voltage = next(v for v in circuit['voltageSources'] if v['positive'] == gate_net and v['negative'] == '0')
            source_id, bias = voltage['id'], voltage['value']
            for kind in ('ac', 'noise'):
                add(identifier + '-s4-' + kind, circuit, frequency_analysis(kind, source_id, 'net:d', dev['temperatureKelvin']), family)
            analysis = {'kind': 'transient', 'initialization': 'operatingPoint', 'uicInitialUnknowns': {},
                'stimulus': {'sourceID': source_id, 'points': [{'timeSeconds': 0., 'value': bias},
                    {'timeSeconds': 2e-9, 'value': bias + .01}, {'timeSeconds': 12e-9, 'value': bias}]},
                'steps': schedule(1e-9)}
            add(identifier + '-s4-transient', circuit, analysis, family)
    for family, identifier in [('BULK', 'bsim-p-loaded'), ('CMG', 'cmg-p-loaded'), ('IMG', 'img-p-forward'), ('SOI', 'soi-p-forward')]:
        circuit = copy.deepcopy(next(c['input'] for c in baseline['cases'] if c['id'] == identifier))
        dev = circuit['devices'][0]
        drain_source = next((v for v in circuit['voltageSources'] if v['positive'] == 'd' and v['negative'] == '0'), None)
        if drain_source is not None:
            drain_source['positive'] = 'supply'
            circuit['resistors'].append(source('RLOAD', 'supply', 'd', 1000.))
            circuit['initialUnknowns']['net:supply'] = drain_source['value']
        gate_net = next(net for name, net in dev['terminals'].items() if name.lower() in ('g', 'fg'))
        voltage = next(v for v in circuit['voltageSources'] if v['positive'] == gate_net and v['negative'] == '0')
        add(identifier + '-forward-valid-s4-noise', circuit, frequency_analysis('noise', voltage['id'], 'net:d', dev['temperatureKelvin']), family)
    for case in cases:
        case['expectedOutcome'] = 'passed'
    return cases


def numeric_rows(point):
    return {row['id']: row for row in point['unknowns']}


def analytic_checks(cases):
    checks = []
    rc = next(c for c in cases if c['id'] == 'analytic-rc-ac')['reference']
    for point in rc['points']:
        expected = .001 * complex(1, .5) / complex(.002, 2 * math.pi * point['frequencyHz'] * 1e-9)
        row = numeric_rows(point)['net:p'];actual = complex(row['real'], row['imag'])
        assert abs(actual - expected) <= 64 * math.ulp(1.) * max(1., abs(expected))
        checks.append('analytic-complex-RC')
    noise = next(c for c in cases if c['id'] == 'analytic-rc-noise')['reference']
    for point in noise['points']:
        f = point['frequencyHz']; y = complex(.002, 2 * math.pi * f * 1e-9)
        expected = (4e-24 + 6e-22 / f + 4 * 1.380649e-23 * 300.15 / 1000.) / abs(y)**2
        assert math.isclose(point['outputDensity'], expected, rel_tol=2e-14, abs_tol=0)
        checks.append('analytic-white-flicker-resistor-PSD')
    ac = numeric_rows(next(c for c in cases if c['id'] == 'analytic-context-ac')['reference']['points'][0])['net:p']
    noise = numeric_rows(next(c for c in cases if c['id'] == 'analytic-context-noise')['reference']['points'][0])['net:p']
    assert abs(complex(ac['real'], ac['imag']) - complex(noise['real'], noise['imag'])) > .01
    checks.append('distinct-AC-noise-profile')
    current_noise = next(c for c in cases if c['id'] == 'analytic-rc-current-noise')['reference']
    assert all(p['inputReferredUnit'] == 'A^2/Hz' for p in current_noise['points'])
    checks.append('current-input-noise-quantity')
    latch = next(c for c in cases if c['id'] == 'analytic-retained-state')['reference']
    assert [numeric_rows(p)['net:p']['value'] for p in latch['points']] == [0., 1., 1., 0., 0.]
    assert latch['rejectedTrials'] == 1
    checks.append('generated-retained-state-reject-accept')
    state = next(c for c in cases if c['id'] == 'analytic-two-slot-state')['reference']
    assert [numeric_rows(p)['net:p']['value'] for p in state['points']] == [0., 1., 0., 0.]
    checks.append('two-native-state-slots')
    uic = next(c for c in cases if c['id'] == 'analytic-uic-rc')['reference']
    assert uic['operatingPoint'] is None and numeric_rows(uic['points'][0])['net:p']['value'] == .7
    checks.append('non-ground-UIC-without-OP')
    return checks


def capture(args):
    guard();started = time.monotonic()
    baseline = BASE.read_json(args.dc_manifest)
    if baseline.get('qualificationComplete') is not True:
        raise ValueError('The exact four-family DC artifact authority is required.')
    for library in baseline['libraries']:
        FAMILIES.checked_file(library)
    compiler = Path(baseline['compiler']['path']);FAMILIES.checked_file(baseline['compiler'])
    if BASE.digest(compiler) != BASE.COMPILER_SHA:
        raise ValueError('Compiler identity mismatch.')
    output = args.output.resolve();output.mkdir(parents=True, exist_ok=False)
    snapshots = output / 'input-snapshots';snapshots.mkdir()
    fixtures = HERE.parents[1] / 'Tests' / 'CoreSpiceOSDITests' / 'Fixtures'
    tool = HERE.parent / 'OSDIDCVerification'
    sources = [tool / 'oracle.c', tool / 'analysis_oracle.c', tool / 'osdi_0_4.h',
               fixtures / 'dc_disciplines.vams', *sorted(fixtures.glob('dynamic_*.va')), Path(__file__),
               args.protocol_source]
    source_records = []
    for path in sources:
        destination = snapshots / path.name;shutil.copyfile(path, destination)
        source_records.append({'name': path.name, 'sourcePath': str(path.resolve()),
                               'snapshotPath': str(destination), 'sha256': BASE.digest(destination)})
    shutil.copyfile(args.dc_manifest, snapshots / 'dc-manifest.json')
    if BASE.digest(snapshots / 'osdi_0_4.h') != BASE.HEADER_SHA:
        raise ValueError('Header identity mismatch.')
    clang = Path(shutil.which(args.clang)).resolve();receipts = []
    oracle = output / 'analysis-oracle'
    run([clang, '-std=c17', '-O1', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function',
         snapshots / 'analysis_oracle.c', '-o', oracle], output, 'compile-oracle', receipts)
    libraries = {entry['id']: entry for entry in baseline['libraries']}
    def compile_va(source):
        destination = output / (source.stem + '.osdi')
        run([compiler, '--full-residuals', '-O', '1', '--target', 'aarch64-apple-darwin', '-I', snapshots,
             source, '-o', destination], output, 'compile-' + source.stem, receipts)
        return {'id': source.stem, 'path': str(destination), 'sha256': BASE.digest(destination),
                'descriptorIndex': 0, 'descriptorName': source.stem}
    with ThreadPoolExecutor(max_workers=2) as pool:
        for library in pool.map(compile_va, sorted(snapshots.glob('dynamic_*.va'))):
            libraries[library['id']] = library
    state_library = output / 'state2.osdi'
    run([clang, '-std=c17', '-O1', '-dynamiclib', '-DPROTOCOL_MODE=0', '-I', snapshots,
         snapshots / args.protocol_source.name, '-o', state_library], output, 'compile-state2', receipts)
    libraries['state2'] = {'id': 'state2', 'path': str(state_library), 'sha256': BASE.digest(state_library),
                           'descriptorIndex': 0, 'descriptorName': 'protocol_transport'}
    cases = make_requests(baseline)
    BASE.save(snapshots / 'requests.json', {'schema': 'corespice.osdi.analysis-inputs.v1', 'cases': cases})
    for case in cases:
        command = dynamic_command(oracle, libraries, case['input'])
        if case['expectedOutcome'] == 'invalidSourcePSD':
            run(command, output, case['id'], receipts, expected=2)
            diagnostic = (output / (case['id'] + '.stderr')).read_text()
            match = re.search(r'device=(\S+) sourceIndex=(\d+) name=(\S+) frequency=(\S+) density=(\S+)', diagnostic)
            if not match or 'invalid source PSD' not in diagnostic:
                raise AssertionError('Expected an explicitly identified invalid generated source PSD')
            failure = {'stage': 'noise', 'reason': 'invalid_source_psd', 'deviceID': match[1],
                       'sourceIndex': int(match[2]), 'sourceName': match[3],
                       'frequencyHz': float(match[4]), 'rawDensity': float(match[5])}
            if failure['rawDensity'] >= 0:
                raise AssertionError('Expected a negative generated PSD, not a repaired source')
            result = {'schema': 'corespice.osdi.analysis-result.v1', 'kind': case['kind'],
                      'status': 'expectedFailure', 'failure': failure}
        else:
            result = json.loads(run(command, output, case['id'], receipts))
            if result['status'] != 'passed':
                raise AssertionError(case['id'] + ' failed physical validation')
        case['reference'] = result
        case['oracleBaseCommand'] = command
        case['validationBaseCommand'] = [sys.executable, str(Path(__file__).resolve()), 'validate',
                                          '--manifest', str(output / 'manifest.json'), '--case-id', case['id']]
    checks = analytic_checks(cases)
    result = {'schema': 'corespice.osdi.analysis-manifest.v1', 'status': 'passed',
              'libraries': list(libraries.values()), 'cases': cases, 'sources': source_records,
              'oracle': {'path': str(oracle), 'sha256': BASE.digest(oracle)},
              'compiler': baseline['compiler'], 'headerSHA256': BASE.HEADER_SHA,
              'compilerProfileReceiptSHA256': BASE.PROFILE_RECEIPT_SHA,
              'dcManifest': {'path': str(args.dc_manifest.resolve()), 'sha256': BASE.digest(args.dc_manifest)},
              'familyMatrix': baseline['familyMatrix'], 'analyticChecks': checks,
              'commands': receipts, 'seconds': time.monotonic() - started}
    for row in source_records:
        assert BASE.digest(row['sourcePath']) == BASE.digest(row['snapshotPath']) == row['sha256']
    for entry in libraries.values():FAMILIES.checked_file(entry)
    BASE.save(output / 'manifest.json', result)
    print(json.dumps({'manifest': str(output / 'manifest.json'), 'sha256': BASE.digest(output / 'manifest.json'),
                      'cases': len(cases), 'analyticChecks': len(checks), 'seconds': result['seconds']}))


def migrate_fixed_bias_noise(args):
    guard();started = time.monotonic()
    parent_path = args.manifest.resolve(strict=True)
    parent = read_analysis_json(parent_path)
    if parent.get('status') != 'passed' or len(parent['cases']) != 50:
        raise ValueError('Migration requires the exact completed fifty-case capture.')
    affected = [case for case in parent['cases'] if case['expectedOutcome'] != 'passed']
    if {case['id'] for case in affected} != SIGNED_NOISE_CASE_IDS:
        raise ValueError('Only the four known signed reverse-noise references may be migrated.')
    for case in affected:
        failure = case['reference'].get('failure', {})
        raw = failure.get('rawDensity')
        if (case['kind'] != 'noise' or case['expectedOutcome'] != 'invalidSourcePSD'
                or case['reference']['status'] != 'expectedFailure' or raw is None
                or not math.isfinite(raw) or raw >= 0):
            raise ValueError('Migration refuses a failure without finite signed-noise evidence.')
    for record in parent['libraries']:
        FAMILIES.checked_file(record)
    FAMILIES.checked_file(parent['oracle'])
    output = args.output.resolve();output.mkdir(parents=True, exist_ok=False)
    snapshots = output / 'input-snapshots';snapshots.mkdir()
    sources = []
    for source in [HERE.parent / 'OSDIDCVerification' / name
                   for name in ('analysis_oracle.c', 'oracle.c', 'osdi_0_4.h')] + [Path(__file__)]:
        snapshot = snapshots / source.name;shutil.copyfile(source, snapshot)
        sources.append({'name': source.name, 'sourcePath': str(source.resolve()),
                        'snapshotPath': str(snapshot), 'sha256': BASE.digest(snapshot)})
    shutil.copyfile(parent_path, snapshots / 'parent-manifest.json')
    if BASE.digest(snapshots / 'osdi_0_4.h') != BASE.HEADER_SHA:
        raise ValueError('Pinned OSDI header identity mismatch.')
    clang = Path(shutil.which(args.clang)).resolve(strict=True)
    oracle = output / 'analysis-oracle';receipts = []
    run([clang, '-std=c17', '-O1', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function',
         snapshots / 'analysis_oracle.c', '-o', oracle], output, 'compile-oracle', receipts)
    result = copy.deepcopy(parent)
    changes = []
    for case, original in zip(result['cases'], parent['cases']):
        if case['id'] in SIGNED_NOISE_CASE_IDS:
            command = [str(oracle)] + original['oracleBaseCommand'][1:]
            reference = json.loads(run(command, output, case['id'], receipts))
            if reference.get('status') != 'passed' or reference['kind'] != 'noise':
                raise AssertionError(case['id'] + ': fresh signed-noise capture did not pass')
            signed_channels = []
            for point in reference['points']:
                for channel in point['channels']:
                    raw = channel['rawSignedDensity']
                    if not math.isfinite(raw) or channel['density'] != abs(raw):
                        raise AssertionError(case['id'] + ': fixed-bias signed noise mismatch')
                    if raw < 0:
                        signed_channels.append({'frequencyHz': point['frequencyHz'],
                                                'id': channel['id'], 'rawSignedDensity': raw})
            if not signed_channels:
                raise AssertionError(case['id'] + ': missing actual signed-noise discriminator')
            case['reference'] = reference;case['expectedOutcome'] = 'passed'
            case['oracleBaseCommand'] = command
            changes.append({'caseID': case['id'], 'before': original['reference'],
                            'signedChannels': signed_channels})
        elif case['reference'] != original['reference']:
            raise AssertionError('Unaffected reference changed')
        if case['input'] != original['input']:
            raise AssertionError('Original request changed')
        case['validationBaseCommand'] = [sys.executable, str(Path(__file__).resolve()), 'validate',
                                         '--manifest', str(output / 'manifest.json'), '--case-id', case['id']]
    binding = {'path': str(oracle), 'sha256': BASE.digest(oracle)}
    result['oracle'] = binding;result['validationOracle'] = binding
    result['commands'] = receipts;result['seconds'] = time.monotonic() - started
    result['derivedFrom'] = {'manifest': {'path': str(parent_path), 'sha256': BASE.digest(parent_path)},
                             'priorDerivation': parent.get('derivedFrom'),
                             'change': 'fixed-bias abs of finite signed native noise; raw values retained',
                             'allInputsUnchanged': True, 'unaffectedReferencesUnchanged': True}
    result['noiseContractMigration'] = {
        'contract': 'fixed-bias-small-signal-abs', 'sources': sources,
        'clang': {'path': str(clang), 'sha256': BASE.digest(clang)},
        'oldPassedCount': sum(case['reference']['status'] == 'passed' for case in parent['cases']),
        'newPassedCount': sum(case['reference']['status'] == 'passed' for case in result['cases']),
        'unchangedReferenceCount': 46, 'recapturedCases': changes}
    if result['noiseContractMigration']['newPassedCount'] != 50:
        raise AssertionError('Migration did not preserve all fifty requested cases')
    BASE.save(output / 'manifest.json', result)
    print(json.dumps({'manifest': str(output / 'manifest.json'), 'sha256': BASE.digest(output / 'manifest.json'),
                      'oldPassed': 46, 'newPassed': 50, 'recaptured': len(changes),
                      'unchangedReferences': 46}))


def validate(args):
    manifest = read_analysis_json(args.manifest);FAMILIES.checked_file(manifest['oracle'])
    validation_oracle = manifest.get('validationOracle', manifest['oracle'])
    FAMILIES.checked_file(validation_oracle)
    candidate_bytes = manifest.get('validationProfile', {}).get('maximumCandidateFileBytes', BASE.MAX_INPUT_BYTES)
    case = next(c for c in manifest['cases'] if c['id'] == args.case_id)
    candidate = read_analysis_json(args.candidate)
    if case['expectedOutcome'] != 'passed':
        raise ValueError('An expected native failure has no completed candidate result.')
    output = args.output.resolve();profile = validation_profile(output, candidate_bytes)
    output.mkdir(parents=True, exist_ok=False)
    request = copy.deepcopy(case['input']);kind = case['kind']
    needs_op = kind != 'transient' or request['analysis']['initialization'] != 'uic'
    if needs_op and candidate.get('operatingPoint') is None:
        raise ValueError('This analysis requires the complete actual operating-point candidate.')
    if not needs_op and candidate.get('operatingPoint') is not None:
        raise ValueError('UIC must not publish a manufactured operating point.')
    if kind == 'transient':
        request['analysis']['steps'] = candidate['acceptedSteps']
        request['analysis'].pop('forcedRejectedTrialIndex', None)
        if len(candidate['points']) != len(candidate['acceptedSteps']) + 1:
            raise ValueError('Transient candidate point/accepted-step counts disagree.')
        if candidate['points'][0]['timeSeconds'] != 0 or any(point['timeSeconds'] != step['timeSeconds'] for point, step in zip(candidate['points'][1:], candidate['acceptedSteps'], strict=True)):
            raise ValueError('Transient candidate times disagree with the actual accepted audit.')
    elif [p['frequencyHz'] for p in candidate['points']] != request['analysis']['frequenciesHz']:
        raise ValueError('Candidate frequency schedule differs from the request.')
    candidate_path = output / 'candidate.txt'
    def candidate_lines():
        for point, sample in enumerate(candidate['points'] if kind != 'noise' else []):
            for row in sample['unknowns']:
                if kind == 'transient':yield f'value {point} {row["id"]} {row["value"]!r}\n'
                else:yield f'complex {point} {row["id"]} {row["real"]!r} {row["imag"]!r}\n'
    bounded_candidate(candidate_path, candidate_lines(), candidate_bytes)
    libraries = {entry['id']: entry for entry in manifest['libraries']}
    for entry in libraries.values():FAMILIES.checked_file(entry)
    command = dynamic_command(validation_oracle['path'], libraries, request)
    if candidate.get('operatingPoint') is not None:
        op_path = output / 'operating-point.txt'
        bounded_candidate(op_path, (f'value 0 {row["id"]} {row["value"]!r}\n' for row in candidate['operatingPoint']), candidate_bytes)
        command += ['--operating-point-file', str(op_path)]
    receipts = []
    # Preserve a failing candidate's receipt and exit without manufacturing success.
    try:
        profile['beforeChildFreeBytes'] = validation_profile(output, candidate_bytes)['observedFreeBytes']
        raw = BASE.run(command + ([] if kind == 'noise' else ['--candidate-file', candidate_path]), output, 'candidate-validation', receipts)
    except RuntimeError as error:
        reason = error.reason if isinstance(error, ValidationResourceFailure) else 'oracle_failure'
        validation_receipt(output, {'status': 'failed', 'commands': receipts, 'ioProfile': profile,
                                    'failure': {'stage': 'validation', 'reason': reason}})
        raise
    validated = json.loads(raw)
    if kind == 'noise':
        reference = validated
        for actual, expected in zip(candidate['points'], reference['points'], strict=True):
            for key in ('outputDensity', 'inputReferredDensity'):
                if not math.isclose(actual[key], expected[key], rel_tol=1e-8, abs_tol=0):
                    raise AssertionError('Noise candidate differs from independent ' + key)
            if actual['inputReferredUnit'] != expected['inputReferredUnit']:
                raise AssertionError('Noise input quantity mismatch')
            if len(actual['channels']) != len(expected['channels']):raise AssertionError('Noise source count mismatch')
            actual_channels = {row['id']: row for row in actual['channels']}
            expected_channels = {row['id']: row for row in expected['channels']}
            if set(actual_channels) != set(expected_channels):raise AssertionError('Noise source identity mismatch')
            for key, e in expected_channels.items():
                a = actual_channels[key]
                if a['residualUnit'] != e['residualUnit'] or not math.isclose(a['density'], e['density'], rel_tol=1e-8, abs_tol=0) or not math.isclose(a['outputDensity'], e['outputDensity'], rel_tol=1e-8, abs_tol=0):
                    raise AssertionError('Noise source identity or contribution mismatch')
        if not math.isclose(candidate['integratedOutputNoise'], reference['integratedOutputNoise'], rel_tol=1e-8, abs_tol=0):
            raise AssertionError('Noise integral mismatch')
    validation_receipt(output, {'status': 'passed', 'commands': receipts, 'ioProfile': profile,
              'candidateSHA256': BASE.digest(args.candidate), 'manifestSHA256': BASE.digest(args.manifest)})
    print(json.dumps({'status': validated['status'], 'receipt': str(output / 'receipt.json')}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    build = commands.add_parser('capture');build.add_argument('--dc-manifest', type=Path, required=True)
    build.add_argument('--protocol-source', type=Path, required=True);build.add_argument('--clang', default='clang')
    build.add_argument('--output', type=Path, required=True)
    migration = commands.add_parser('migrate-fixed-bias-noise')
    migration.add_argument('--manifest', type=Path, required=True);migration.add_argument('--output', type=Path, required=True)
    migration.add_argument('--clang', default='clang')
    replay = commands.add_parser('validate');replay.add_argument('--manifest', type=Path, required=True)
    replay.add_argument('--case-id', required=True);replay.add_argument('--candidate', type=Path, required=True)
    replay.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    {'capture': capture, 'validate': validate, 'migrate-fixed-bias-noise': migrate_fixed_bias_noise}[arguments.command](arguments)
