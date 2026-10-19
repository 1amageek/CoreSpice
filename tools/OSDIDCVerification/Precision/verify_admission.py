#!/usr/bin/env python3
"""Finding-specific immutable-node and exact-version admission controls."""
import argparse
import base64
import copy
from dataclasses import replace
import json
from pathlib import Path
import signal
import struct
import time

import artifact as a
import binding
import driver
import replay_artifact as caller


def seal(record, admitted):
    """Recompute consistency framing without borrowing admission being tested."""
    execution = record['osdiExecution']
    precision = execution['precision']
    originals = {x['instanceName'].casefold(): x for x in record['osdiModels'] if x['phase'] == 'tran'}
    models = []
    for old, cold in zip(admitted.models, precision['coldModels']):
        program = cold['program']
        original = originals[old.name]
        models.append(replace(old, original=original, cold=cold,
                              program=base64.b64decode(program['programBytes']),
                              setup=base64.b64decode(program['setupBytes']),
                              raw_to_global=tuple(original['rawNodeGlobalRows'])))
    identity, _ = binding.expected_identity(replace(admitted, record=record, execution=execution,
                                                   precision=precision, models=tuple(models)))
    record['configurationIdentity'] = precision['configurationSHA256'] = identity


def duplicate_raw(record):
    precision = record['osdiExecution']['precision']
    program = precision['coldModels'][0]['program']
    nodes = program['topology']['nodes']
    assert len(nodes) == 1
    nodes.append(dict(nodes[0], index=1))
    original = record['osdiModels'][0]
    for key in ('rawNodeGlobalRows', 'rawNodeNames', 'rawNodeUnits', 'rawEquationUnits'):
        original[key].append(original[key][0])
    setup = bytearray(base64.b64decode(program['setupBytes']))
    offset = len(setup)
    setup.extend(struct.pack('<II', 0, 0))
    struct.pack_into('<QII', setup, 64, offset, 2, 4)
    struct.pack_into('<Q', setup, 8, len(setup))
    program['setupBytes'] = base64.b64encode(setup).decode()
    program['setupSHA256'] = a.sha(setup)


def main():
    signal.alarm(30)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', required=True)
    parser.add_argument('--precision-manifest', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=False)
    record, record_identity = a.strict_json(args.artifact)
    manifest, manifest_identity = a.strict_json(args.precision_manifest)
    admitted = a.decode(record, manifest)
    original_point = caller.point
    point_calls = 0
    def forbidden_point(*args, **kwargs):
        nonlocal point_calls
        point_calls += 1
        raise AssertionError('point_called_before_admission')
    caller.point = forbidden_point
    checks = []
    def check(name, mutate, reason, reseal=False):
        damaged = copy.deepcopy(record)
        mutate(damaged)
        if reseal:
            seal(damaged, admitted)
        destination = out/name
        destination.mkdir()
        try:
            caller.replay(a.decode(damaged, manifest), Path('/unexecuted'), destination, time.monotonic()+5)
        except a.Refusal as error:
            assert str(error) == reason, (name, str(error), reason)
            assert not (destination/'models').exists()
            checks.append({'case': name, 'reason': str(error), 'pointCalls': point_calls, 'passed': True})
        else:
            raise AssertionError('corruption_accepted:'+name)
    try:
        def node(record):
            return record['osdiExecution']['precision']['coldModels'][0]['program']['topology']['nodes'][0]
        check('changed-node-flow-resealed', lambda x: node(x).__setitem__('isFlow', True), 'program_topology_node_flow', True)
        check('changed-node-name-resealed', lambda x: (node(x).__setitem__('name', 'renamed'), x['osdiModels'][0]['rawNodeNames'].__setitem__(0, 'renamed')), 'program_topology_node_name', True)
        check('raw-count-mismatch-resealed', duplicate_raw, 'program_topology_raw_count', True)
        check('boolean-node-index', lambda x: node(x).__setitem__('index', False), 'integer_bounds')
        check('boolean-precision-version', lambda x: x['osdiExecution']['precision'].__setitem__('schemaVersion', True), 'precision_schema')
        check('float-precision-version', lambda x: x['osdiExecution']['precision'].__setitem__('schemaVersion', 1.0), 'precision_schema')
        check('float-execution-version', lambda x: x['osdiExecution'].__setitem__('schemaVersion', 2.0), 'precision_schema')
        check('float-outer-version', lambda x: x.__setitem__('schemaVersion', 4.0), 'outer_schema')
        check('boolean-semver-component', lambda x: x.__setitem__('schemaVersion', {'major': 4, 'minor': False, 'patch': 0}), 'outer_schema')
        check('float-model-record-version', lambda x: x['osdiModels'][0].__setitem__('schemaVersion', 2.0), 'model_record_schema')
        positive = copy.deepcopy(record)
        positive['schemaVersion'] = {'major': 4, 'minor': 0, 'patch': 0}
        a.decode(positive, manifest)
    finally:
        caller.point = original_point
    assert point_calls == 0
    snapshots = out/'sources'; snapshots.mkdir()
    sources = []
    for source in (Path(__file__), Path(a.__file__), Path(binding.__file__), Path(caller.__file__)):
        target = snapshots/source.name
        target.write_bytes(source.read_bytes())
        sources.append(driver.identity(target))
    driver.write_json(out/'verification.json', {'schema': 'corespice.independent-paired-admission-controls.v1',
                      'scope': 'Finding-only immutable node facts and integer schema versions, before point calls.',
                      'passed': True, 'checks': checks, 'pointCalls': point_calls,
                      'unchangedPositiveAndIntegerSemverPassed': True,
                      'artifact': record_identity, 'precisionManifest': manifest_identity, 'sources': sources})
    print(json.dumps({'passed': True, 'controls': len(checks), 'pointCalls': point_calls}))


if __name__ == '__main__':
    main()
