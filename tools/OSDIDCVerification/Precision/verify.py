#!/usr/bin/env python3
"""Independent oracle behavioral controls; generated schema fixtures are not model images."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import re
import struct
import driver

NONE = 0xffffffff
STRIDES = [8, 16, 24, 24, 40, 24, 16, 24, 32, 16, 1]


def dyadic(value):
    value = value['significand']
    return -int(value[1:], 2) if value.startswith('-') else int(value, 2)


def endpoint(value):
    return Fraction(dyadic(value)) * Fraction(2) ** value['exponent']


def enclosure(value):
    return endpoint(value['lowerBinary']), endpoint(value['upperBinary'])


def contains(value, expected):
    lo, hi = enclosure(value)
    return lo <= expected <= hi


def pack_table(fmt, rows):
    return b''.join(struct.pack('<' + fmt, *row) for row in rows)


def fixture(kind):
    """Independent authored pure-CFG fixtures, with exact published layout."""
    regs = [1, 1, 1, 3, 1, 1, 1]
    constants = [(0, 1, 0), (1, 1, struct.unpack('<Q', struct.pack('<d', 1.0))[0])]
    instructions = [(47, 2, 1, 0, NONE, 0)]
    blocks = [(0, 0, 0, 0, 0, 0, NONE, NONE, NONE, 0),
              (1, 0, 0, 0, 0, 0, NONE, NONE, NONE, 0)]
    root = 1
    phis = []
    if kind in ('inactive-select', 'active-root'):
        constants.append((3, 3, 0))
        instructions.append((74, 4, 3, 2, 1, 0))
        blocks.append((2, 0, 2, 0, 0, 0, NONE, NONE, NONE, 0))
        root = 2 if kind == 'active-root' else 4
    else:
        instructions.append((54, 3, 2, 0, NONE, 0))
        blocks.append((2, 0, 2, 0, 0, 2, 3, 3, 4, 0))
        instructions.extend([(44, 4, 1, 1, NONE, 0), (45, 5, 1, 0, NONE, 0)])
        blocks.extend([(2, 2, 1, 0, 0, 1, NONE, 5, NONE, 0),
                       (2, 3, 1, 0, 0, 1, NONE, 5, NONE, 0),
                       (2, 4, 0, 0, 2, 0, NONE, NONE, NONE, 0)])
        phis = [(6, 3, 4, 0), (6, 4, 5, 0)]
        if kind == 'live-join':
            root = 6
        elif kind == 'effect':
            instructions[2] = (73, NONE, 1, NONE, NONE, 0)
        elif kind == 'loop':
            blocks[3] = (2, 2, 1, 0, 0, 1, NONE, 3, NONE, 0)
        elif kind == 'no-join':
            blocks[3] = (2, 2, 1, 0, 0, 0, NONE, NONE, NONE, 0)
            blocks[4] = (2, 3, 1, 0, 0, 0, NONE, NONE, NONE, 0)
    functions = [(1, 0, 0, 1, 0, 0), (2, 1, 1, 1, 0, 0),
                 (3, 2, 2, len(blocks)-2, 0, 0)]
    tables = [pack_table('II', [(x, 0) for x in regs]), pack_table('IIQ', constants), b'',
              pack_table('6I', functions), pack_table('10I', blocks),
              pack_table('6I', instructions), pack_table('4I', phis),
              pack_table('6I', [(2, 1, root, 0, NONE, 0), (2, 2, 0, 0, NONE, 0)]),
              b'', pack_table('4I', [(0, 0, 1, 0)]), b'p']
    header = struct.pack('<8sIIQIIII32s', b'OSDIPR1', 1, 248, 0, 1, 0, 1, 0, bytes(32))
    offset, sections, body = 248, [], b''
    for stride, table in zip(STRIDES, tables):
        padding = (-offset) % 8
        body += bytes(padding)
        offset += padding
        sections.append(struct.pack('<QII', offset, len(table)//stride, stride))
        body += table
        offset += len(table)
    result = bytearray(header + b''.join(sections) + body)
    struct.pack_into('<Q', result, 16, len(result))
    raw_map = struct.pack('<I', 0)
    setup = (struct.pack('<IIQQII', 1, 96, 100,
                        struct.unpack('<Q', struct.pack('<d', 300.15))[0], 1, 1) +
             struct.pack('<QII', 96, 0, 16) + struct.pack('<QII', 96, 0, 24) +
             struct.pack('<QII', 96, 1, 4) + struct.pack('<QII', 100, 0, 1) + raw_map)
    return result, setup


def selfchecks(binary, directory):
    directory.mkdir(parents=True, exist_ok=False)
    results = []
    kinds = ('inactive-select', 'active-root', 'inactive-region', 'live-join',
             'effect', 'loop', 'no-join', 'bad-opcode', 'bad-root', 'work-limit')
    for kind in kinds:
        case = directory / (kind + '-inputs')
        case.mkdir()
        program, setup = fixture('inactive-select' if kind.startswith('bad-') or kind == 'work-limit' else kind)
        if kind == 'bad-opcode':
            offset = struct.unpack_from('<Q', program, 72 + 5*16)[0]
            struct.pack_into('<I', program, offset, 999)
        if kind == 'bad-root':
            offset = struct.unpack_from('<Q', program, 72 + 7*16)[0]
            struct.pack_into('<I', program, offset + 12, 1)
        (case/'program').write_bytes(program)
        (case/'setup').write_bytes(setup)
        receipt = driver.replay(binary, case/'program', case/'setup', [[0.0]]*4,
                                [{'mode': 2, 'high': 1.0, 'low': 0.0},
                                 {'mode': 2, 'high': 0.0, 'low': 0.0}], directory/kind,
                                work=1 if kind == 'work-limit' else 1000000)
        expected = kind in ('inactive-select', 'inactive-region')
        passed = (receipt['status'] == 'passed') == expected
        if expected and passed:
            output = json.loads((directory/kind/'point.stdout').read_text())
            passed = contains(output['rows'][0]['F'], Fraction(1))
        results.append({'case': kind, 'expectedSuccess': expected, 'passed': passed,
                        'receipt': driver.identity(directory/kind/'receipt.json')})
    driver.write_json(directory/'verification.json', {'schema': 'corespice.independent-precision-controls.v1',
                      'tool': driver.identity(__file__), 'binary': driver.identity(binary),
                      'cases': results, 'passed': all(x['passed'] for x in results)})
    if not all(x['passed'] for x in results):
        raise RuntimeError('control_failure: ' + ','.join(x['case'] for x in results if not x['passed']))
    return results


def source_controls(compound_output, img_output, img_report, source, compound_source):
    """Source-derived rational controls, independent of either SSA interpreter."""
    compound_text = re.sub(r'\s+', '', Path(compound_source).read_text())
    for expression in ('parameterrealk=10000000000000000.0+1.0;',
                       'I(p)<+(k-10000000000000000.0)+V(p)*V(p)+ddt(1.0e-9*V(p));'):
        if expression not in compound_text:
            raise AssertionError('compound_source_premise')
    compound = json.loads(Path(compound_output).read_text())['rows'][0]
    x = Fraction(1) + Fraction(2)**-60
    qfactor = Fraction(float('1e-9'))
    full = Fraction(1) + x*x
    tangent = Fraction(2) + 2*Fraction(2)**-60
    if not contains(compound['F'], full) or contains(compound['F'], tangent):
        raise AssertionError('full_nonlinear_source')
    if not contains(compound['deltaQ'], qfactor*Fraction(2)**-60):
        raise AssertionError('compound_deltaQ')
    if contains(compound['F'], x*x):
        raise AssertionError('compound_default_fold')
    text = Path(source).read_text()
    defaults = {}
    for name in ('NFMOD', 'NF', 'XW', 'WINT', 'WL', 'WW', 'WWL', 'CTH0', 'WTH0'):
        match = re.search(r'`\w+\(\s*' + name + r'\s*,\s*([^,]+)', text)
        if not match:
            raise AssertionError('source_default_missing:' + name)
        defaults[name] = Fraction(float(match.group(1).strip()))
    if any(defaults[x] != 0 for x in ('NFMOD', 'XW', 'WINT', 'WL', 'WW', 'WWL', 'WTH0')) or defaults['NF'] != 1:
        raise AssertionError('source_geometry_premise')
    report = json.loads(Path(img_report).read_text())
    params = {x['name']: x['value'] for x in report['input']['model']['parameters']}
    if any(x in params for x in defaults):
        raise AssertionError('source_default_overridden')
    width = Fraction(params['W']['real'])
    cth = defaults['CTH0'] * width
    img = json.loads(Path(img_output).read_text())['rows'][4]
    expected = cth * Fraction(2)**-60
    if not contains(img['deltaQ'], expected) or contains(img['deltaQ'], Fraction(0)):
        raise AssertionError('thermal_sub_ulp_deltaQ')
    # Both binary64 Q endpoints round identically; their subtraction is a false zero.
    if float(cth * (Fraction(4)+Fraction(2)**-60)) != float(cth*4):
        raise AssertionError('rounded_Q_witness_premise')
    return {'compoundFullF': str(full), 'tangentF': str(tangent),
            'imgCTH': str(cth), 'imgDeltaQ': str(expected),
            'compoundSource': driver.identity(compound_source),
            'compoundEvaluation': driver.identity(compound_output),
            'imgEvaluation': driver.identity(img_output),
            'tool': driver.identity(__file__),
            'imgSource': driver.identity(source), 'imgPreparation': driver.identity(img_report)}


def compare_worker(binary, worker_report, directory):
    """Independently evaluate exact paired inputs, then compare exact dyadic sets."""
    directory.mkdir(parents=True, exist_ok=False)
    report = json.loads(Path(worker_report).read_text())
    results = []
    for name, data in report['families'].items():
        for key in ('program', 'setup'):
            if driver.identity(data[key+'Path'])['sha256'] != data[key+'SHA256']:
                raise AssertionError(key+'_identity_mismatch')
        if data['status'] != 0:
            raise AssertionError('worker_not_successful:' + name)
        receipt = driver.replay(binary, data['programPath'], data['setupPath'],
                                data['vectors'], data['contexts'], directory/name)
        if receipt['status'] != 'passed':
            raise AssertionError('independent_point_failure:' + name)
        output = json.loads((directory/name/'point.stdout').read_text())
        failures, channels = [], 0
        for row in output['rows']:
            i = row['index']
            for key, offset in (('F', 0), ('deltaQ', 3)):
                lo, hi = enclosure(row[key])
                center = Fraction(data['outputs'][offset][i]) + Fraction(data['outputs'][offset+1][i])
                radius = Fraction(data['outputs'][offset+2][i])
                channels += 1
                if not center-radius <= lo <= hi <= center+radius:
                    failures.append({'row': i, 'channel': key,
                                     'oracleLower': str(lo), 'oracleUpper': str(hi),
                                     'workerLower': str(center-radius), 'workerUpper': str(center+radius)})
        results.append({'family': name, 'passed': not failures, 'channels': channels,
                        'failures': failures,
                        'receipt': driver.identity(directory/name/'receipt.json')})
    result = {'schema': 'corespice.independent-precision-containment.v1',
              'workerReport': driver.identity(worker_report), 'tool': driver.identity(__file__),
              'independentBinary': driver.identity(binary), 'families': results,
              'passed': all(x['passed'] for x in results)}
    driver.write_json(directory/'comparison.json', result)
    if not result['passed']:
        raise AssertionError('worker_enclosure_mismatch')
    return results


def compare_public_reports(public_directory, worker_report, independent_receipt, output):
    """Lift an existing independent result through exact public CLI input/output identity."""
    import hashlib
    import math
    reference = json.loads(Path(worker_report).read_text())['families']
    proof = json.loads(Path(independent_receipt).read_text())
    if not proof['passed'] or proof['workerReport']['sha256'] != driver.identity(worker_report)['sha256']:
        raise AssertionError('independent_premise_mismatch')
    keys = ('fHigh', 'fLow', 'fRadius', 'deltaQHigh', 'deltaQLow', 'deltaQRadius', 'g', 'c')
    def bits(x):
        return struct.unpack('<Q', struct.pack('<d', x))[0]
    def exact_vector(record, expected):
        if record['bitPatterns'] != [bits(x) for x in expected]:
            raise AssertionError('component_bits_mismatch')
        if len(record['values']) != len(expected):
            raise AssertionError('component_shape')
        for number, pattern in zip(record['values'], record['bitPatterns']):
            decoded = struct.unpack('<d', struct.pack('<Q', pattern))[0]
            if not math.isfinite(decoded) or number != decoded:
                raise AssertionError('component_value_mismatch')
    rows = []
    for family, expected in reference.items():
        path = Path(public_directory)/(family+'-report.json')
        driver.identity(path)
        actual = json.loads(path.read_text())
        if not actual['succeeded']:
            raise AssertionError('public_failure')
        for key in ('program', 'setup'):
            blob = bytes(actual['program'][key+'Bytes'])
            digest = hashlib.sha256(blob).hexdigest()
            if digest != expected[key+'SHA256'] or digest != actual['program'][key+'SHA256']:
                raise AssertionError('public_'+key+'_mismatch')
        for key, vector in zip(('candidateHigh', 'candidateLow', 'referenceHigh', 'referenceLow'), expected['vectors']):
            exact_vector(actual['input'][key], vector)
        for key, context in zip(('candidateContext', 'referenceContext'), expected['contexts']):
            value = actual['input'][key]
            expected_mode = 'transient' if context['mode'] == 2 else 'transientInitialization'
            if value['mode'] != expected_mode or value['timeHighBits'] != bits(context['high']) or value['timeLowBits'] != bits(context['low']):
                raise AssertionError('public_context_mismatch')
        for key, vector in zip(keys, expected['outputs']):
            exact_vector(actual['evaluation'][key], vector)
        rows.append({'family': family, 'report': driver.identity(path),
                     'channels': len(expected['outputs'][0])*2, 'passed': True})
    result = {'schema': 'corespice.independent-precision-public-path.v1',
              'independentComparison': driver.identity(independent_receipt),
              'workerReport': driver.identity(worker_report), 'tool': driver.identity(__file__),
              'publicReceipt': driver.identity(Path(public_directory)/'receipt.json'),
              'families': rows, 'passed': True,
              'scope': 'Exact public CLI paired inputs/program/setup/eight output arrays match the already independently enclosed worker results; no duplicate numerical run.'}
    driver.write_json(output, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--worker-report')
    args = parser.parse_args()
    results = (compare_worker(Path(args.binary).resolve(), args.worker_report, Path(args.output).resolve())
               if args.worker_report else selfchecks(Path(args.binary).resolve(), Path(args.output).resolve()))
    print(json.dumps({'passed': True, 'checks': len(results)}))


if __name__ == '__main__':
    main()
