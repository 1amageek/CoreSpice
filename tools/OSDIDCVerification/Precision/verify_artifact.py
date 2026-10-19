#!/usr/bin/env python3
"""Synthetic wire corruption and independent caller controls, not production evidence."""
import argparse
import base64
import copy
from decimal import Decimal, localcontext
from fractions import Fraction
import json
from pathlib import Path
import shutil
import signal
import struct
import time

import artifact as a
import binding
import driver
import replay_artifact as caller


def reference(data, kind='source', format_name='spice'):
    canonical = b'CircuiteArtifactContent\0\0\1\0\6sha256\0\x20'+bytes.fromhex(a.sha(data))+len(data).to_bytes(8, 'big')
    return {'id': canonical.hex(), 'descriptor': {'kind': kind, 'format': format_name, 'role': 'input'}}


def fixture(public_point, manifest):
    """Author independently solved BE/TR source steps using an already exported program."""
    lower, _ = a.strict_json(public_point)
    program = copy.deepcopy(lower['program'])
    program['programBytes'] = base64.b64encode(bytes(program['programBytes'])).decode()
    program['setupBytes'] = base64.b64encode(bytes(program['setupBytes'])).decode()
    h, current = 2.0**-54, 2.0+2.0**-30
    with localcontext() as context:
        context.prec = 100
        capacitance = Decimal.from_float(1e-9)
        dt = Decimal.from_float(h)
        drive = Decimal.from_float(current)-2
        coefficient = Decimal(2)+capacitance/dt
        low = float(2*drive/((coefficient*coefficient+4*drive).sqrt()+coefficient))
    with localcontext() as context:
        context.prec = 100
        z1 = Decimal.from_float(low)
        coefficient = Decimal(2)+2*capacitance/dt
        previous_iq = capacitance*z1/dt
        constant = -drive-2*capacitance*z1/dt-previous_iq
        low2 = float(-2*constant/((coefficient*coefficient-4*constant).sqrt()+coefficient))
    source = ('Synthetic paired caller control\n.model model osdi\nN1 p model\n'
              f'I1 p 0 {-current!r}\n.ic V(p)=1\n'
              '.options gmin=0 reltol=1e-10 abstol=1e-12 vntol=1e-9 itl1=80\n'
              f'.tran {h!r} {2*h!r} 0 {h!r} uic\n.end\n').encode()
    nodes = program['topology']['nodes']
    outer = {'schemaVersion': 2, 'profile': 'nativeOSDI.analysis.v2', 'phase': 'tran',
             'instanceName': 'n1', 'modelName': 'model', 'artifact': program['modelReference'],
             'descriptorIndex': 0, 'expectedDescriptorName': 'precision_compound',
             'modelParameters': [], 'instanceParameters': [], 'previousState': [], 'resolvedParameters': [],
             'effectiveKelvin': 300.15, 'rawNodeGlobalRows': [0],
             'rawNodeNames': [x['name'] for x in nodes], 'rawNodeUnits': [x['units'] for x in nodes],
             'rawEquationUnits': [x['residualUnits'] for x in nodes], 'completedPointCount': 3}
    settings = {'analysis': 'tran', 'analysisIndex': 0, 'seed': 0,
                'temperatureKelvin': 300.15, 'nominalTemperatureKelvin': 300.15,
                'convergence': {'abstol': 1e-12, 'vntol': 1e-9, 'reltol': 1e-10, 'gmin': 0,
                                'minDamping': .01, 'opticalPowerTolerance': 1e-12, 'maxIterations': 80},
                'transient': {'stopTime': 2*h, 'maxTimeStep': h, 'minTimeStep': h/16, 'lteTolerance': 1e-3,
                              'initialTimeStep': h, 'preferredMethod': 'backwardEuler', 'useInitialConditions': True,
                              'shrinkFactor': .5, 'maxTimeStepReductions': 20, 'gminSteppingThreshold': 3,
                              'initialGmin': .01, 'finalGmin': 0, 'gminReductionFactor': 10, 'maximumGminSteps': 20},
                'numericalLimits': {'maximumAcceptedSteps': 1000, 'maximumSolveAttempts': 10000,
                                    'maximumNewtonIterations': 1000000, 'maximumSavedScalars': 100000,
                                    'maximumMatrixDimension': 128, 'maximumWorkUnits': 100000000,
                                    'maximumBreakpoints': 1000},
                'initialConditions': [{'row': 0, 'value': 1}], 'nodeSets': []}
    precision = {'schemaVersion': 1, 'configurationSHA256': '1'*64, 'sourceInputIdentity': '2'*64,
                 'legacyBaseDigest': '3'*64, 'solverIdentity': binding.SOLVER,
                 'algorithmIdentity': a.ALGORITHM,
                 'executionBudget': {'maximumNativeAllocationBytes': 256*1024*1024,
                                     'maximumLiveOwnedBytes': 256*1024*1024,
                                     'maximumTemporaryBytes': 512*1024*1024,
                                     'maximumHashedBytes': 512*1024*1024, 'maximumEvidenceBytes': 64*1024*1024},
                 'sources': {'rootKey': 'root', 'captures': [{'key': 'root', 'reference': reference(source),
                                                           'bytes': base64.b64encode(source).decode()}],
                             'occurrences': [{'key': 'root', 'occurrenceID': 0}]},
                 'settings': settings, 'equationPolicy': [{'row': 0, 'kind': 'electricalPotential',
                                                         'variableAbsoluteTolerance': 1e-9, 'equationAbsoluteTolerance': 1e-12}],
                 'coldModels': [{'instanceName': 'n1', 'program': program, 'workerReference': lower['workerReference'],
                                 'numericProfileSHA256': manifest['numericProfileSHA256'],
                                 'options': manifest['options'], 'precisionBits': manifest['precisionBits']}],
                 'solutionLow': [0, low, low2], 'highBits': [a.bits(1)]*3, 'lowBits': [0, a.bits(low), a.bits(low2)],
                 'coordinateBits': [0, a.bits(h), a.bits(2*h)], 'endpointLowComponent': 0,
                 'operatingPointRepresentation': 'absent-uic', 'displayRepresentation': 'rounded-binary64'}
    step = {'timeSeconds': h, 'timeStepSeconds': h, 'timeStepLowComponent': 0,
            'timeSecondsBits': a.bits(h), 'timeStepBits': a.bits(h), 'timeStepLowBits': 0,
            'method': 'backwardEuler'}
    step2 = dict(step, timeSeconds=2*h, timeSecondsBits=a.bits(2*h), method='trapezoidal',
                 previousTimeStepSeconds=h, previousTimeStepLowComponent=0,
                 previousTimeStepBits=a.bits(h), previousTimeStepLowBits=0)
    execution = {'schemaVersion': 2, 'analysis': 'tran', 'precision': precision,
                 'rows': [{'row': 0, 'kind': 'node', 'sourceName': 'p', 'unit': 'V'}],
                 'columns': [{'name': 'V(p)', 'unit': 'V', 'compiledRow': 0}], 'sweepName': 'time', 'sweepUnit': 's',
                 'coordinates': [0, h, 2*h], 'real': [1, 1, 1], 'acceptedSteps': [step, step2], 'projectedColumns': [0]}
    record = {'schemaVersion': 4, 'status': 'succeeded', 'configurationIdentity': '1'*64,
            'sourceInputIdentity': '2'*64, 'points': 3, 'newtonIterations': 1,
            'osdiModels': [outer], 'osdiExecution': execution, 'diodeModels': []}
    configuration, _ = binding.expected_identity(a.decode_structure(record, manifest))
    precision['configurationSHA256'] = record['configurationIdentity'] = configuration
    return record


def controls(record, manifest):
    """Structural controls isolate the canonical-v6 binding seam while it is frozen."""
    base = copy.deepcopy(record)
    a.decode_structure(base, manifest)
    tests = []
    def check(name, mutate):
        damaged = copy.deepcopy(base)
        mutate(damaged)
        try:
            a.decode_structure(damaged, manifest)
        except a.Refusal as error:
            tests.append({'case': name, 'passed': True, 'reason': str(error)})
        else:
            raise AssertionError('corruption_accepted:'+name)
    def p(x): return x['osdiExecution']['precision']
    check('missing-lows', lambda x: p(x).pop('solutionLow'))
    check('low-bit-mismatch', lambda x: p(x)['lowBits'].__setitem__(1, 0))
    check('signed-zero-low-bit-mismatch', lambda x: p(x)['lowBits'].__setitem__(0, 1<<63))
    check('coordinate-bit-mismatch', lambda x: p(x)['coordinateBits'].__setitem__(1, a.bits(1)))
    check('unnormalized-pair', lambda x: (p(x)['solutionLow'].__setitem__(1, 1), p(x)['lowBits'].__setitem__(1, a.bits(1))))
    check('relaxed-equation-gate', lambda x: p(x)['equationPolicy'][0].__setitem__('equationAbsoluteTolerance', 1e-6))
    check('wrong-raw-global-map', lambda x: x['osdiModels'][0]['rawNodeGlobalRows'].__setitem__(0, None))
    check('wrong-row-nature', lambda x: x['osdiExecution']['rows'][0].__setitem__('unit', 'K'))
    check('first-TR', lambda x: x['osdiExecution']['acceptedSteps'][0].__setitem__('method', 'trapezoidal'))
    check('wrong-h-low', lambda x: x['osdiExecution']['acceptedSteps'][0].update(timeStepLowComponent=2**-110, timeStepLowBits=a.bits(2**-110)))
    check('spurious-previous-h', lambda x: x['osdiExecution']['acceptedSteps'][0].update(previousTimeStepSeconds=2**-54, previousTimeStepLowComponent=0, previousTimeStepBits=a.bits(2**-54), previousTimeStepLowBits=0))
    check('false-initialization', lambda x: p(x)['settings']['transient'].__setitem__('useInitialConditions', False))
    check('changed-effective-gmin', lambda x: p(x)['settings']['convergence'].__setitem__('gmin', 1e-3))
    check('malformed-program-base64', lambda x: p(x)['coldModels'][0]['program'].__setitem__('programBytes', '!!!!'))
    check('program-digest-mismatch', lambda x: p(x)['coldModels'][0]['program'].__setitem__('programSHA256', '0'*64))
    check('setup-digest-mismatch', lambda x: p(x)['coldModels'][0]['program'].__setitem__('setupSHA256', '0'*64))
    check('source-digest-mismatch', lambda x: p(x)['sources']['captures'][0].__setitem__('bytes', base64.b64encode(b'bad source').decode()))
    check('wrong-scoped-given', lambda x: x['osdiModels'][0]['modelParameters'].append({'name': 'k', 'scope': 'model', 'type': 'real', 'value': 2}))
    def simulation_override(x):
        program = p(x)['coldModels'][0]['program']
        setup = bytearray(base64.b64decode(program['setupBytes']))
        pool_offset, pool_count = a.table(setup, 3, 1, 96)
        pool = bytes(setup[pool_offset:pool_offset+pool_count])+b'gmin'
        strings_at = len(setup)
        setup.extend(pool)
        facts_at = len(setup)
        setup.extend(struct.pack('<IIIIQ', pool_count, 4, 1, 1, a.bits(1e-3)))
        struct.pack_into('<QII', setup, 48, facts_at, 1, 24)
        struct.pack_into('<QII', setup, 80, strings_at, len(pool), 1)
        struct.pack_into('<Q', setup, 8, len(setup))
        program['setupBytes'] = base64.b64encode(setup).decode()
        program['setupSHA256'] = a.sha(setup)
    check('injected-simulation-override', simulation_override)
    check('wrong-worker', lambda x: p(x)['coldModels'][0].__setitem__('workerReference', reference(b'not the worker', 'tool', 'executable')))
    check('changed-profile', lambda x: p(x)['coldModels'][0].__setitem__('numericProfileSHA256', '0'*64))
    check('changed-options', lambda x: p(x)['coldModels'][0]['options'].__setitem__('arenaBytes', 1))
    check('noninteger-bit-pattern', lambda x: p(x)['coordinateBits'].__setitem__(0, False))
    a.decode(base, manifest)
    def binding_check(name, mutate):
        damaged = copy.deepcopy(base)
        mutate(damaged)
        try:
            a.decode(damaged, manifest)
        except a.Refusal as error:
            tests.append({'case': name, 'passed': True, 'reason': str(error)})
        else:
            raise AssertionError('binding_corruption_accepted:'+name)
    from dataclasses import replace
    decoded = a.decode(base, manifest)
    for name, field, value in (('row-number', 'row', 1), ('row-kind', 'kind', 'branch'),
                               ('row-name', 'sourceName', 'other'), ('row-unit', 'unit', 'K')):
        execution = copy.deepcopy(decoded.execution)
        execution['rows'][0][field] = value
        try:
            binding.verify(replace(decoded, execution=execution))
        except a.Refusal as error:
            tests.append({'case': 'committed-compiled-'+name, 'passed': True, 'reason': str(error)})
        else:
            raise AssertionError('compiled_row_binding_accepted:'+name)
    binding_check('changed-legacy-base', lambda x: p(x).__setitem__('legacyBaseDigest', '4'*64))
    binding_check('changed-solver', lambda x: p(x).__setitem__('solverIdentity', 'other-solver'))
    binding_check('changed-thermal-policy-witness', lambda x: p(x)['equationPolicy'][0].__setitem__('equationAbsoluteTolerance', 1e-13))
    binding_check('changed-saved-settings', lambda x: p(x)['settings']['transient'].__setitem__('lteTolerance', 1e-4))
    binding_check('changed-resolved-fact', lambda x: x['osdiModels'][0]['resolvedParameters'].append(
        {'name': 'k', 'scope': 'model', 'type': 'real', 'value': 2, 'descriptorIndex': 0, 'isGiven': False}))
    binding_check('changed-source-input-identity', lambda x: (x.__setitem__('sourceInputIdentity', '5'*64), p(x).__setitem__('sourceInputIdentity', '5'*64)))
    binding_check('missing-native-witness', lambda x: p(x).pop('legacyBaseDigest'))
    binding_check('opaque-configuration-only', lambda x: (x.__setitem__('configurationIdentity', '6'*64), p(x).__setitem__('configurationSHA256', '6'*64)))
    return tests


def main():
    signal.alarm(60)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-compound-point', required=True)
    parser.add_argument('--precision-manifest', required=True)
    parser.add_argument('--oracle-build', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=False)
    manifest, manifest_identity = a.strict_json(args.precision_manifest)
    record = fixture(args.public_compound_point, manifest)
    driver.write_json(out/'synthetic-artifact.json', record)
    tests = controls(record, manifest)
    binary, engine = caller.verify_engine(args.oracle_build)
    positive = out/'physical-positive'; positive.mkdir()
    evaluated = caller.replay(a.decode(record, manifest), binary, positive, time.monotonic()+30)
    damaged = copy.deepcopy(record)
    damaged['osdiExecution']['precision']['solutionLow'][1] = 0
    damaged['osdiExecution']['precision']['lowBits'][1] = 0
    negative = out/'physical-negative'; negative.mkdir()
    try:
        caller.replay(a.decode(damaged, manifest), binary, negative, time.monotonic()+30)
    except a.Refusal as error:
        tests.append({'case': 'physical-zeroed-consistent-low', 'passed': True, 'reason': str(error)})
    else:
        raise AssertionError('zeroed_low_trajectory_accepted')
    from trajectory import Interval
    exact = [Interval(Fraction(0), Fraction(1, 2**512))]
    state = list(exact)
    for index in range(1000):
        h = Fraction((1<<52)+2*index+1, 1<<100)
        value = Interval(Fraction(0), Fraction(1, 2**512)).scale(2/h)-state[0]
        bounded = caller.bounded_history([value])[0]
        assert bounded.lower <= value.lower <= value.upper <= bounded.upper
        for endpoint in (bounded.lower, bounded.upper):
            assert endpoint.numerator.bit_length() <= 512
            assert endpoint.denominator & (endpoint.denominator-1) == 0
        state = [bounded]
    tests.append({'case': '1000-variable-h-outward-history-bound', 'passed': True})
    snapshots = out/'sources'; snapshots.mkdir()
    files = []
    for source in (Path(__file__), Path(a.__file__), Path(binding.__file__), Path(caller.__file__)):
        target = snapshots/source.name
        shutil.copyfile(source, target)
        files.append(driver.identity(target))
    driver.write_json(out/'verification.json', {'schema': 'corespice.independent-paired-artifact-controls.v1',
                      'scope': 'Synthetic decoder/v6-binding/caller controls; no production trajectory is claimed.',
                      'sources': files, 'precisionManifest': manifest_identity, 'oracleBuild': engine,
                      'structuralPositive': True, 'physicalPositive': evaluated,
                      'checks': tests, 'passed': True})
    print(len(tests), 'corruption controls and two synthetic BE/TR steps passed')


if __name__ == '__main__':
    main()
