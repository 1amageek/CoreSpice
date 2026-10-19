#!/usr/bin/env python3
"""Refute missing qualification authority without executing a model or worker."""
import argparse
import contextlib
import copy
import io
from pathlib import Path

import driver


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('qualification', 'base-request', 'analysis-manifest', 'worker-receipt', 'osdi-root', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    qualification = driver.read(args.qualification)
    baseline = driver.read(args.base_request)
    analysis = driver.read(args.analysis_manifest)
    worker = driver.read(args.worker_receipt)
    wrong_numeric = copy.deepcopy(driver.read(driver.fact(worker['numericProfile'])['path']))
    wrong_numeric['worker']['sha256'] = '0' * 64
    wrong_numeric_path = output / 'wrong-worker-numeric-profile.json'
    driver.save(wrong_numeric_path, wrong_numeric)
    wrong_numeric_fact = driver.identity(wrong_numeric_path)
    checks = []
    controls = (
        ('failed-qualification', 'qualification', lambda value: value.update(passed=False), 'soi_qualification'),
        ('missing-polarity-mode', 'qualification', lambda value: value['cases'].pop(), 'four_polarity_mode_selectors'),
        ('source-identity', 'qualification', lambda value: value['source'].update(sha256='0' * 64), 'input_identity:'),
        ('worker-identity', 'worker_receipt', lambda value: value['worker'].update(sha256='0' * 64), 'input_identity:'),
        ('profile-worker-association', 'worker_receipt', lambda value: value.update(numericProfile=wrong_numeric_fact), 'numeric_profile_worker_binding'),
        ('relaxed-equation-gate', 'base_request', lambda value: value['circuit']['policy']['equationAbsoluteTolerances'].update(A=1e-6), 'original_base_request_identity'),
        ('changed-relative-gate', 'base_request', lambda value: value['circuit']['policy'].update(relativeTolerance=1e-6), 'original_base_request_identity'),
        ('changed-middle-knot', 'analysis_manifest', lambda value: next(case['input']['analysis'] for case in value['cases'] if case['kind'] == 'transient')['stimulus']['points'][1].update(value=0.62), 'original_analysis_manifest_identity'),
    )
    originals = {'qualification': qualification, 'base_request': baseline, 'worker_receipt': worker,
                 'analysis_manifest': analysis}
    for name, key, mutate, expected in controls:
        altered = copy.deepcopy(originals[key])
        mutate(altered)
        mutation = output / (name + '.json')
        driver.save(mutation, altered)
        selected = copy.copy(args)
        setattr(selected, key, mutation)
        selected.output = output / name
        captured = io.StringIO()
        try:
            with contextlib.redirect_stdout(captured):
                driver.prepare(selected)
        except ValueError as error:
            driver.require(str(error).startswith(expected), name + ':unexpected_refusal:' + str(error))
            driver.require(not (selected.output / 'inputs.json').exists(), name + ':partial_success_published')
            checks.append({'case': name, 'mutation': driver.identity(mutation), 'refusal': str(error)})
        else:
            raise RuntimeError(name + ':invalid_authority_accepted')
    driver.save(output / 'receipt.json', {'schema': 'corespice.soi101.precision-admission-controls.v1',
                'status': 'passed', 'checks': checks,
                'sources': [driver.identity(__file__), driver.identity(driver.__file__)]})
    print('Eight latest SOI qualification authority controls passed; no model/worker execution.')


if __name__ == '__main__':
    main()
