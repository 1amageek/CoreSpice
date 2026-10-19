#!/usr/bin/env python3
"""Bounded behavioral checks for the independent precision circuit assembly."""
import argparse
from fractions import Fraction as F
from pathlib import Path
import shutil
import signal
import driver
import trajectory as t


def verify(output):
    checks = []
    def record(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append({'case': name, 'passed': True})
    eps = F(1, 10**15)
    first = 1+eps
    circuit = {'resistors': [{'id': 'R', 'positive': 'x', 'negative': '0', 'value': 1}],
               'capacitors': [{'id': 'C', 'positive': 'x', 'negative': '0', 'value': 1}],
               'currentSources': [{'id': 'I', 'positive': 'x', 'negative': '0', 'value': -2}]}
    f, q = t.assemble_external(circuit, {'x': 0}, {}, [first], [F(0)], F(1), None)
    iq, _, merit = t.accepted_step(f, q, [t.ZERO], F(1), 'backwardEuler', [1e-12])
    record('BE-original-RC', merit < 1)
    second = F(5, 3)+eps
    f, q = t.assemble_external(circuit, {'x': 0}, {}, [second], [first], F(2), None)
    iq2, _, merit = t.accepted_step(f, q, iq, F(1), 'trapezoidal', [1e-12])
    record('TR-actual-Iq-history', merit == 0 and iq2[0].lower == F(1, 3)-eps)
    record('TR-never-minus-previous-F', iq[0].lower != 1-eps)
    low = F(2)**-60
    circuit = {'capacitors': [{'id': 'C', 'positive': 'x', 'negative': '0', 'value': 1}],
               'currentSources': [{'id': 'I', 'positive': 'x', 'negative': '0', 'value': -1}]}
    f, q = t.assemble_external(circuit, {'x': 0}, {}, [1+low], [F(1)], low, None)
    _, _, merit = t.accepted_step(f, q, [t.ZERO], low, 'backwardEuler', [1e-12])
    record('sub-ULP-charge-preserved', merit == 0)
    _, _, wrong = t.accepted_step(f, [t.ZERO], [t.ZERO], low, 'backwardEuler', [1e-12])
    record('rounded-high-charge-rejected', wrong > 1)
    circuit = {'resistors': [{'id': 'R', 'positive': 'x', 'negative': '0', 'value': 1}],
               'voltageSources': [{'id': 'V', 'positive': 'x', 'negative': '0', 'value': 1}]}
    f, q = t.assemble_external(circuit, {'x': 0}, {'v': 1}, [F(1), F(-1)], [F(1), F(-1)], F(1), None)
    _, _, merit = t.accepted_step(f, q, [t.ZERO]*2, F(1), 'backwardEuler', [1e-12, 1e-10])
    record('voltage-source-MNA-sign', merit == 0)
    f, q = t.assemble_external(circuit, {'x': 0}, {'v': 1}, [F(1), F(1)], [F(1), F(-1)], F(1), None)
    _, _, merit = t.accepted_step(f, q, [t.ZERO]*2, F(1), 'backwardEuler', [1e-12, 1e-10])
    record('wrong-source-current-rejected', merit > 1)
    f, q = [t.Interval.scalar(-1)], [t.ZERO]
    t.map_model_rows(f, q, [0, 0], [t.Interval.scalar(F(3, 10)), t.Interval.scalar(F(7, 10))], [t.ZERO]*2)
    record('all-alias-raw-residuals-summed', f[0].magnitude() == 0)
    _, _, merit = t.accepted_step([t.Interval.scalar(F(2, 10**12))], [t.ZERO], [t.ZERO], F(1), 'backwardEuler', [1e-12])
    record('thermal-original-absolute-gate', merit > 1)
    # Inductor Q has the negative branch sign: V - L*DeltaI/h = 0.
    circuit = {'inductors': [{'id': 'L', 'positive': 'x', 'negative': '0', 'value': 2}],
               'currentSources': [{'id': 'I', 'positive': 'x', 'negative': '0', 'value': -1}]}
    f, q = t.assemble_external(circuit, {'x': 0}, {'l': 1}, [F(2), F(1)], [F(0), F(0)], F(1), None)
    _, _, merit = t.accepted_step(f, q, [t.ZERO]*2, F(1), 'backwardEuler', [1e-12, 1e-10])
    record('inductor-branch-Q-sign', merit == 0)
    output.mkdir(parents=True, exist_ok=False)
    for source in (Path(__file__), Path(t.__file__)):
        shutil.copyfile(source, output/source.name)
    result = {'schema': 'corespice.independent-precision-assembly.v1', 'passed': True,
              'sources': [driver.identity(output/name) for name in ('verify_assembly.py', 'trajectory.py')],
              'checks': checks}
    driver.write_json(output/'verification.json', result)
    return result


def main():
    signal.alarm(30)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    result = verify(Path(args.output).resolve())
    print(len(result['checks']), 'assembly controls passed')


if __name__ == '__main__':
    main()
