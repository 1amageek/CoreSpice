#!/usr/bin/env python3
"""Finding-only available integration-history admission controls; no point calls."""
import argparse
import copy
import json
from pathlib import Path
import signal
import time

import artifact as a
import driver
import replay_artifact as caller

PREVIOUS = ('previousTimeStepSeconds', 'previousTimeStepLowComponent', 'previousTimeStepBits', 'previousTimeStepLowBits')


def clear_previous(step):
    for key in PREVIOUS:
        step.pop(key, None)


def main():
    signal.alarm(30)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', required=True)
    parser.add_argument('--precision-manifest', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve(); output.mkdir(parents=True, exist_ok=False)
    record, artifact_identity = a.strict_json(args.artifact)
    manifest, manifest_identity = a.strict_json(args.precision_manifest)
    a.decode(record, manifest)
    assert len(record['osdiExecution']['acceptedSteps']) >= 2
    assert record['osdiExecution']['acceptedSteps'][1]['method'] == 'trapezoidal'
    checks = []
    positive = copy.deepcopy(record)
    step = positive['osdiExecution']['acceptedSteps'][1]
    step['method'] = 'backwardEuler'; clear_previous(step)
    a.decode(positive, manifest)
    checks.append({'case': 'later-BE-completely-absent-previous-positive', 'passed': True})
    point_calls = 0
    original = caller.point
    def forbidden(*args, **kwargs):
        nonlocal point_calls
        point_calls += 1
        raise AssertionError('point_started_before_admission')
    caller.point = forbidden
    def reject(name, mutate, reason):
        damaged = copy.deepcopy(record)
        mutate(damaged['osdiExecution']['acceptedSteps'])
        directory = output/name; directory.mkdir()
        try:
            caller.replay(a.decode(damaged, manifest), Path('/unexecuted'), directory, time.monotonic()+5)
        except a.Refusal as error:
            assert str(error) == reason, (name, str(error))
            assert not (directory/'models').exists()
            checks.append({'case': name, 'passed': True, 'reason': str(error)})
        else:
            raise AssertionError('invalid_history_accepted:'+name)
    try:
        reject('TR-absent-previous', lambda steps: clear_previous(steps[1]), 'missing_previous_history')
        reject('BE-partial-previous', lambda steps: (steps[1].__setitem__('method', 'backwardEuler'), steps[1].pop('previousTimeStepLowComponent')), "missing_or_malformed_field:'previousTimeStepLowComponent'")
        reject('BE-absent-high-partial-bits', lambda steps: (steps[1].__setitem__('method', 'backwardEuler'), steps[1].pop('previousTimeStepSeconds')), 'missing_previous_history')
        reject('supplied-previous-mismatch', lambda steps: steps[1].update(previousTimeStepSeconds=2**-55, previousTimeStepBits=a.bits(2**-55)), 'previous_interval_history')
        reject('first-BE-supplied-previous', lambda steps: steps[0].update({key: steps[1][key] for key in PREVIOUS}), 'previous_interval_history')
    finally:
        caller.point = original
    assert point_calls == 0
    snapshots = output/'sources'; snapshots.mkdir()
    sources = []
    for source in (Path(__file__), Path(a.__file__), Path(caller.__file__)):
        target = snapshots/source.name; target.write_bytes(source.read_bytes()); sources.append(driver.identity(target))
    driver.write_json(output/'verification.json', {'schema': 'corespice.independent-integration-history-controls.v1',
                      'scope': 'Available previous integration context admission only; no physical trajectory claim.',
                      'passed': True, 'checks': checks, 'pointCalls': point_calls,
                      'artifact': artifact_identity, 'precisionManifest': manifest_identity, 'sources': sources})
    print(json.dumps({'passed': True, 'controls': len(checks), 'pointCalls': point_calls}))


if __name__ == '__main__':
    main()
