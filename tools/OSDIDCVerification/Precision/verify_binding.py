#!/usr/bin/env python3
"""Saved-current and forged-version Native binding controls without point evaluation."""
import argparse
import copy
from dataclasses import replace
import json
from pathlib import Path
import signal
import sys

sys.dont_write_bytecode = True
import artifact as a
import binding
import driver
import replay_artifact as caller


def main():
    signal.alarm(30)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', required=True)
    parser.add_argument('--precision-manifest', required=True)
    parser.add_argument('--analysis-manifest', required=True)
    parser.add_argument('--case-id', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    record, artifact_identity = a.strict_json(args.artifact)
    manifest, manifest_identity = a.strict_json(args.precision_manifest)
    analysis, analysis_identity = a.strict_json(args.analysis_manifest)
    cases = [x for x in analysis['cases'] if x['id'] == args.case_id]
    a.require(len(cases) == 1 and cases[0]['kind'] == 'transient', 'analysis_case')
    case = cases[0]
    point_calls = 0
    original_point = caller.point
    def forbidden_point(*args, **kwargs):
        nonlocal point_calls
        point_calls += 1
        raise AssertionError('binding_control_called_numerical_point')
    caller.point = forbidden_point
    checks = []
    try:
        precision = record['osdiExecution']['precision']
        a.require(precision['algorithmIdentity'] == a.ALGORITHM and precision['solverIdentity'] == binding.SOLVER,
                  'expected_current_saved_binding')
        admitted = a.decode(record, manifest, case)
        checks.append(dict(case='actual-saved-current-binding', passed=True,
                           configurationIdentity=record['configurationIdentity']))

        def reject(name, mutate, reason):
            damaged = copy.deepcopy(record)
            mutate(damaged['osdiExecution']['precision'])
            try:
                a.decode(damaged, manifest, case)
            except a.Refusal as error:
                assert str(error) == reason, (name, str(error), reason)
                checks.append(dict(case=name, passed=True, reason=str(error)))
            else:
                raise AssertionError('binding_corruption_accepted:' + name)

        reject('unknown-solver-version', lambda p: p.__setitem__('solverIdentity', 'CoreSpice.SparseLU.SwiftCSC.v3'),
               'binding_algorithm_solver')
        reject('unknown-historical-solver-version', lambda p: p.__setitem__('solverIdentity', 'CoreSpice.SparseLU.Accelerate.v2'),
               'binding_algorithm_solver')
        reject('unsupported-old-algorithm', lambda p: p.__setitem__('algorithmIdentity',
               'CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v2'), 'precision_algorithm_context')
        reject('unknown-algorithm-version', lambda p: p.__setitem__('algorithmIdentity',
               'CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v4'), 'precision_algorithm_context')
        reject('supported-solver-with-unchanged-commitment',
               lambda p: p.__setitem__('solverIdentity', binding.LEGACY_SOLVER), 'native_v6_configuration_mismatch')
        reject('changed-legacy-base', lambda p: p.__setitem__('legacyBaseDigest', '0' * 64),
               'native_v6_configuration_mismatch')

        # A separately framed historical contract is a consistency control, not
        # a claim that this current trace was produced by the historical solver.
        historical = copy.deepcopy(record)
        historical_precision = historical['osdiExecution']['precision']
        historical_precision['solverIdentity'] = binding.LEGACY_SOLVER
        historical_identity, _ = binding.expected_identity(replace(admitted, record=historical,
            execution=historical['osdiExecution'], precision=historical_precision))
        assert historical_identity != record['configurationIdentity']
        historical_precision['configurationSHA256'] = historical['configurationIdentity'] = historical_identity
        a.decode(historical, manifest, case)
        checks.append(dict(case='separately-framed-historical-contract', passed=True,
                           configurationIdentity=historical_identity, numericalReplay=False))
    finally:
        caller.point = original_point
    assert point_calls == 0
    snapshots = output / 'sources'
    snapshots.mkdir()
    sources = []
    for path in (Path(__file__), Path(a.__file__), Path(binding.__file__), Path(caller.__file__)):
        target = snapshots / path.name
        target.write_bytes(path.read_bytes())
        sources.append(driver.identity(target))
    driver.write_json(output / 'verification.json', dict(schema='corespice.independent-binding-controls.v1',
        status='passed', artifact=artifact_identity, precisionManifest=manifest_identity,
        analysisManifest=analysis_identity, caseID=args.case_id, checks=checks, pointCalls=point_calls,
        sources=sources, scope='Saved current binding and exact version/commitment controls; no numerical replay'))
    print(json.dumps(dict(status='passed', controls=len(checks), pointCalls=point_calls)))


if __name__ == '__main__':
    main()
