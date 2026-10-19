#!/usr/bin/env python3
"""Independent exact interval circuit assembly for accepted precision trajectories."""
from dataclasses import dataclass
from fractions import Fraction
import math


@dataclass(frozen=True)
class Interval:
    lower: Fraction
    upper: Fraction

    def __post_init__(self):
        if self.lower > self.upper:
            raise ValueError('invalid_interval')

    @staticmethod
    def scalar(value):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError('nonfinite_scalar')
        value = Fraction(value)
        return Interval(value, value)

    def __add__(self, other):
        return Interval(self.lower+other.lower, self.upper+other.upper)

    def __neg__(self):
        return Interval(-self.upper, -self.lower)

    def __sub__(self, other):
        return self + -other

    def scale(self, factor):
        factor = Fraction(factor)
        a, b = self.lower*factor, self.upper*factor
        return Interval(min(a, b), max(a, b))

    def magnitude(self):
        return max(abs(self.lower), abs(self.upper))


ZERO = Interval.scalar(0)


def pair(high, low):
    if not math.isfinite(high) or not math.isfinite(low) or high+low != high:
        raise ValueError('unnormalized_components')
    return Fraction(high)+Fraction(low)


def waveform_value(source, stimulus, time):
    """Captured PWL leaves are binary64 facts; interpolation is exact rational."""
    if stimulus is None or source['id'].casefold() != stimulus['sourceID'].casefold():
        return Fraction(source['value'])
    points = stimulus['points']
    if not points:
        raise ValueError('empty_source_waveform')
    knots = [(Fraction(x['timeSeconds']), Fraction(x['value'])) for x in points]
    if any(a[0] >= b[0] for a, b in zip(knots, knots[1:])):
        raise ValueError('nonincreasing_source_waveform')
    if time <= knots[0][0]:
        return knots[0][1]
    for (t0, v0), (t1, v1) in zip(knots, knots[1:]):
        if time <= t1:
            return v0+(v1-v0)*(time-t0)/(t1-t0)
    return knots[-1][1]


def assemble_external(circuit, node_rows, branch_rows, current, reference, time, stimulus):
    """Original MNA F and DeltaQ for captured R/C/L/V/I; no model physics."""
    allowed = {'id', 'devices', 'resistors', 'capacitors', 'inductors', 'voltageSources',
               'currentSources', 'initialUnknowns', 'policy', 'expectedOutcome', 'analyticUnknowns'}
    if any(key not in allowed and value for key, value in circuit.items()):
        raise ValueError('unsupported_external_element')
    dimension = len(current)
    if len(reference) != dimension:
        raise ValueError('point_shape')
    f, dq = [ZERO]*dimension, [ZERO]*dimension
    def node(name):
        if name.casefold() in ('0', 'gnd'):
            return None
        try:
            return node_rows[name.casefold()]
        except KeyError as error:
            raise ValueError('missing_external_node:'+name) from error
    def value(vector, index):
        return Fraction(0) if index is None else vector[index]
    def add(rows, index, item):
        if index is not None:
            if not 0 <= index < dimension:
                raise ValueError('global_axis')
            rows[index] = rows[index]+item
    def branch(source):
        try:
            return branch_rows[source['id'].casefold()]
        except KeyError as error:
            raise ValueError('missing_branch:'+source['id']) from error
    for element in circuit.get('resistors', []):
        p, n = node(element['positive']), node(element['negative'])
        resistance = Fraction(element['value'])
        if resistance <= 0:
            raise ValueError('nonpositive_resistance')
        flow = Interval.scalar((value(current, p)-value(current, n))/resistance)
        add(f, p, flow); add(f, n, -flow)
    for element in circuit.get('capacitors', []):
        p, n = node(element['positive']), node(element['negative'])
        capacitance = Fraction(element['value'])
        if capacitance < 0:
            raise ValueError('negative_capacitance')
        charge = Interval.scalar(capacitance*((value(current, p)-value(current, n))-
                                              (value(reference, p)-value(reference, n))))
        add(dq, p, charge); add(dq, n, -charge)
    for element in circuit.get('inductors', []):
        p, n, row = node(element['positive']), node(element['negative']), branch(element)
        inductance = Fraction(element['value'])
        if inductance <= 0:
            raise ValueError('nonpositive_inductance')
        flow = Interval.scalar(current[row])
        add(f, p, flow); add(f, n, -flow)
        add(f, row, Interval.scalar(value(current, p)-value(current, n)))
        add(dq, row, Interval.scalar(-inductance*(current[row]-reference[row])))
    for element in circuit.get('voltageSources', []):
        p, n, row = node(element['positive']), node(element['negative']), branch(element)
        flow = Interval.scalar(current[row])
        add(f, p, flow); add(f, n, -flow)
        add(f, row, Interval.scalar(value(current, p)-value(current, n)-
                                   waveform_value(element, stimulus, time)))
    for element in circuit.get('currentSources', []):
        p, n = node(element['positive']), node(element['negative'])
        flow = Interval.scalar(waveform_value(element, stimulus, time))
        add(f, p, flow); add(f, n, -flow)
    return f, dq


def map_model_rows(f, dq, mapping, model_f, model_dq):
    if len(mapping) != len(model_f) or len(mapping) != len(model_dq):
        raise ValueError('raw_mapping_shape')
    for row, rf, rq in zip(mapping, model_f, model_dq):
        if row is not None:
            if not 0 <= row < len(f):
                raise ValueError('model_global_axis')
            f[row], dq[row] = f[row]+rf, dq[row]+rq


def accepted_step(f, dq, previous_iq, h, method, equation_tolerances):
    h = Fraction(h)
    if h <= 0 or not len(f) == len(dq) == len(previous_iq) == len(equation_tolerances):
        raise ValueError('accepted_step_shape')
    if method not in ('backwardEuler', 'trapezoidal'):
        raise ValueError('unsupported_integration_method')
    iq = [charge.scale((1 if method == 'backwardEuler' else 2)/h) for charge in dq]
    if method == 'trapezoidal':
        iq = [value-previous for value, previous in zip(iq, previous_iq)]
    residuals = [value+reactive for value, reactive in zip(f, iq)]
    normalized = []
    for residual, tolerance in zip(residuals, equation_tolerances):
        tolerance = Fraction(tolerance)
        if tolerance <= 0:
            raise ValueError('invalid_equation_tolerance')
        normalized.append(residual.magnitude()/tolerance)
    return iq, residuals, max(normalized, default=Fraction(0))
