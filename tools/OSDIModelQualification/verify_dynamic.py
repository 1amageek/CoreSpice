#!/usr/bin/env python3
"""Bounded candidate-replay and separate time-accuracy checks for a frozen capture."""
from argparse import ArgumentParser, Namespace
from contextlib import redirect_stdout
from pathlib import Path
import copy
import importlib.util
import io
import json
import math
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('dynamic', Path(__file__).with_name('dynamic.py'))
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)


def refined(steps, divisor):
    result = []
    for step in steps:
        start = step['timeSeconds'] - step['timeStepSeconds']
        for index in range(divisor):
            result.append({'timeSeconds': start + (index + 1) * step['timeStepSeconds'] / divisor,
                           'timeStepSeconds': step['timeStepSeconds'] / divisor, 'method': step['method']})
    return result


def values(result, coordinate, stride=1):
    return [D.numeric_rows(point)[coordinate]['value'] for point in result['points'][::stride]]


def verify(args):
    D.guard()
    manifest = D.read_analysis_json(args.manifest)
    D.FAMILIES.checked_file(manifest['oracle'])
    output = args.output.resolve();output.mkdir(parents=True, exist_ok=False)
    checks, commands = [], []
    for case in manifest['cases']:
        if case['expectedOutcome'] != 'passed':
            assert case['reference']['failure']['rawDensity'] < 0
            continue
        candidate = output / (case['id'] + '.json')
        D.BASE.save(candidate, case['reference'])
        with redirect_stdout(io.StringIO()):
            D.validate(Namespace(manifest=args.manifest, case_id=case['id'], candidate=candidate,
                                 output=output / ('replay-' + case['id'])))
        checks.append({'check': 'complete-candidate-replay', 'caseID': case['id'], 'passed': True})
    for identifier, mutation in [('analytic-rc-ac', 'complex'), ('analytic-nonlinear-q', 'trajectory'),
                                  ('analytic-rc-noise', 'PSD')]:
        case = next(c for c in manifest['cases'] if c['id'] == identifier)
        candidate = copy.deepcopy(case['reference'])
        if mutation == 'complex':
            candidate['points'][0]['unknowns'][0]['real'] += .01
        elif mutation == 'trajectory':
            candidate['points'][1]['unknowns'][0]['value'] += .01
        else:
            candidate['points'][0]['channels'][0]['density'] *= 2
        path = output / ('wrong-' + mutation + '.json');D.BASE.save(path, candidate)
        try:
            with redirect_stdout(io.StringIO()):
                D.validate(Namespace(manifest=args.manifest, case_id=identifier, candidate=path,
                                     output=output / ('reject-' + mutation)))
        except (RuntimeError, AssertionError, ValueError):
            checks.append({'check': 'reject-wrong-' + mutation, 'passed': True})
        else:
            raise AssertionError('Wrong candidate accepted: ' + mutation)
    libraries = {entry['id']: entry for entry in manifest['libraries']}
    accuracy = []
    for case in (() if args.candidates_only else manifest['cases']):
        if case['kind'] != 'transient' or (not case['family'] and case['id'] not in ('analytic-uic-rc', 'analytic-nonlinear-q')):
            continue
        coordinate = 'net:d' if case['family'] else 'net:p'
        coarse = case['reference'];grids = [coarse]
        for divisor in (2, 4):
            request = copy.deepcopy(case['input'])
            request['analysis']['steps'] = refined(request['analysis']['steps'], divisor)
            command = D.dynamic_command(manifest['oracle']['path'], libraries, request)
            result = json.loads(D.run(command, output, f'{case["id"]}-h{divisor}', commands))
            assert result['status'] == 'passed'
            grids.append(result)
        vectors = [values(result, coordinate, divisor) for result, divisor in zip(grids, (1, 2, 4))]
        e12 = max(abs(a - b) for a, b in zip(vectors[0], vectors[1], strict=True))
        e24 = max(abs(a - b) for a, b in zip(vectors[1], vectors[2], strict=True))
        floor = 256 * math.ulp(max(1., *(abs(x) for x in vectors[2])))
        assert e24 <= .75 * e12 + floor, (case['id'], e12, e24, floor)
        change = max(abs(x - vectors[0][0]) for x in vectors[0])
        assert change > floor, (case['id'], 'no measurable transient effect')
        record = {'caseID': case['id'], 'coordinate': coordinate, 'unit': 'V', 'coarseFineDifference': e12,
                  'fineFinerDifference': e24, 'roundoffFloor': floor, 'transientChange': change, 'passed': True}
        if not case['family']:
            exact = []
            q3 = 2e-9 if case['id'] == 'analytic-nonlinear-q' else 0
            for point in coarse['points']:
                t = point['timeSeconds'];lo, hi = 0., .5
                if t == 0:
                    exact.append(.7);continue
                for _ in range(80):
                    v = (lo + hi) * .5
                    elapsed = 1e-6 * math.log(.5 / v) + 3 * q3 / .002 * (.25 - v * v)
                    if elapsed > t:lo = v
                    else:hi = v
                exact.append(.2 + (lo + hi) * .5)
            errors = [max(abs(a - b) for a, b in zip(vector, exact, strict=True)) for vector in vectors]
            assert errors[1] <= .75 * errors[0] + floor and errors[2] <= .75 * errors[1] + floor
            record['analyticExactMaximumErrors'] = errors
        accuracy.append(record)
    # Replay an actual variable-step mixed-method trajectory against its own audit.
    case = next(c for c in manifest['cases'] if c['id'] == 'analytic-uic-rc')
    request = copy.deepcopy(case['input']);h = 2e-8;elapsed = 0.;steps = []
    for index, multiplier in enumerate((.5, .5, 2., 1., 2., 3., 3.)):
        step = h * multiplier;elapsed += step
        steps.append({'timeSeconds': elapsed, 'timeStepSeconds': step,
                      'method': 'backwardEuler' if index < 3 else 'trapezoidal'})
    request['analysis']['steps'] = steps
    candidate = json.loads(D.run(D.dynamic_command(manifest['oracle']['path'], libraries, request),
                                 output, 'variable-step-mixed-method', commands))
    path = output / 'variable-step-candidate.json';D.BASE.save(path, candidate)
    with redirect_stdout(io.StringIO()):
        D.validate(Namespace(manifest=args.manifest, case_id=case['id'], candidate=path,
                             output=output / 'replay-variable-step-mixed-method'))
    checks.append({'check': 'actual-variable-step-mixed-method-audit-replay', 'passed': True})
    latest_tools = {};source_correspondence = []
    for entry in manifest['sources']:
        assert D.BASE.digest(entry['snapshotPath']) == entry['sha256']
        source_correspondence.append({'sourcePath': entry['sourcePath'], 'snapshotSHA256': entry['sha256'],
                                      'currentMatchesSnapshot': D.BASE.digest(entry['sourcePath']) == entry['sha256']})
        if entry['name'] in ('source_sweep.py', 'dynamic.py'):
            latest_tools[entry['name']] = entry
    for entry in latest_tools.values():
        assert D.BASE.digest(entry['sourcePath']) == entry['sha256']
    result = {'status': 'passed', 'manifest': str(args.manifest.resolve()),
              'manifestSHA256': D.BASE.digest(args.manifest), 'checks': checks, 'timeAccuracy': accuracy,
              'commands': commands, 'sourceCorrespondence': source_correspondence,
              'verifierSHA256': D.BASE.digest(__file__)}
    D.BASE.save(output / 'verification.json', result)
    print(json.dumps({'status': 'passed', 'checks': len(checks), 'timeAccuracyCases': len(accuracy),
                      'receipt': str(output / 'verification.json')}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--candidates-only', action='store_true', help='Reuse unchanged time-accuracy evidence.')
    verify(parser.parse_args())
