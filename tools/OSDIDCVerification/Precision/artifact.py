"""Independent bounded decoder for the public precision paired-artifact wire."""
from dataclasses import dataclass, replace
from fractions import Fraction
import base64
import hashlib
import json
import math
from pathlib import Path
import re
import struct

MAX_JSON = 64*1024*1024
MAX_SOURCE = 8*1024*1024
MAX_ROWS = 128
MAX_STEPS = 1000
ALGORITHM = 'CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3'
NONE = 0xffffffff


class Refusal(ValueError):
    """An invalid or unsupported qualification input, never a successful result."""


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(value):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), 'digest_encoding')
    return value


def integer(value, maximum=(1<<64)-1):
    require(type(value) is int and 0 <= value <= maximum, 'integer_bounds')
    return value


def real(value):
    require(type(value) in (int, float) and math.isfinite(value), 'nonfinite_scalar')
    return float(value)


def bits(value):
    return struct.unpack('<Q', struct.pack('<d', real(value)))[0]


def from_bits(value):
    return struct.unpack('<d', struct.pack('<Q', integer(value)))[0]


def exact_pair(high, low):
    high, low = real(high), real(low)
    require(high+low == high, 'unnormalized_pair')
    return Fraction(high)+Fraction(low)


def strict_json(path, maximum=MAX_JSON):
    path = Path(path)
    require(path.stat().st_size <= maximum, 'json_byte_limit')
    data = path.read_bytes()
    depth, quoted, escape = 0, False, False
    for byte in data:
        if quoted:
            if escape:
                escape = False
            elif byte == 92:
                escape = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            require(depth <= 64, 'json_depth_limit')
        elif byte in (93, 125):
            depth -= 1
            require(depth >= 0, 'json_nesting')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate_json_key')
            result[key] = value
        return result
    def bad_constant(_):
        raise Refusal('json_nonfinite_constant')
    try:
        result = json.loads(data, object_pairs_hook=pairs, parse_constant=bad_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise Refusal('json_encoding') from error
    stack, count = [result], 0
    while stack:
        value = stack.pop()
        count += 1
        require(count <= 2_000_000, 'json_value_limit')
        if isinstance(value, dict):
            stack.extend(value.values())
        elif isinstance(value, list):
            stack.extend(value)
        elif type(value) is float:
            require(math.isfinite(value), 'json_nonfinite_number')
    return result, {'path': str(path.resolve()), 'sha256': sha(data), 'byteCount': len(data)}


def canonical_bytes(text, maximum):
    require(isinstance(text, str) and len(text) <= ((maximum+2)//3)*4, 'base64_byte_limit')
    try:
        result = base64.b64decode(text, validate=True)
    except (ValueError, TypeError) as error:
        raise Refusal('base64_encoding') from error
    require(len(result) <= maximum and base64.b64encode(result).decode('ascii') == text, 'base64_canonical')
    return result


def artifact_identity(reference):
    """Published CF ArtifactID v1 big-endian framing; no CF decoder reuse."""
    require(isinstance(reference, dict), 'artifact_reference')
    encoded = reference['id']
    require(isinstance(encoded, str) and re.fullmatch('[0-9a-f]+', encoded) and len(encoded) <= 1024 and len(encoded)%2 == 0, 'artifact_id_encoding')
    data = bytes.fromhex(encoded)
    prefix = b'CircuiteArtifactContent\0\0\1\0\6sha256\0\x20'
    require(data.startswith(prefix) and len(data) == len(prefix)+40, 'artifact_id_profile')
    return {'sha256': data[len(prefix):len(prefix)+32].hex(),
            'byteCount': int.from_bytes(data[-8:], 'big')}


def table(blob, index, stride, header=248):
    require(len(blob) >= header and 0 <= index < (11 if header == 248 else 4), 'table_header')
    offset, count, actual_stride = struct.unpack_from('<QII', blob, (72 if header == 248 else 32)+16*index)
    require(actual_stride == stride and offset >= header and offset <= len(blob) and count <= (len(blob)-offset)//stride, 'table_bounds')
    return offset, count


def string(pool, offset, size):
    require(offset <= len(pool) and size <= len(pool)-offset, 'pool_bounds')
    try:
        return pool[offset:offset+size].decode('utf-8')
    except UnicodeError as error:
        raise Refusal('pool_encoding') from error


def check_setup(program, setup, outer, topology):
    require(program[:8] == b'OSDIPR1\0' and len(program) >= 248, 'program_header')
    require(struct.unpack_from('<IIQ', program, 8) == (1, 248, len(program)), 'program_length')
    require(struct.unpack_from('<I', program, 24)[0] == 1 and struct.unpack_from('<I', program, 36)[0] == 0, 'stateless_program')
    require(len(setup) >= 96 and struct.unpack_from('<IIQ', setup) == (1, 96, len(setup)), 'setup_header')
    kelvin = struct.unpack_from('<d', setup, 16)[0]
    require(bits(kelvin) == bits(outer['effectiveKelvin']) and kelvin > 0, 'setup_kelvin')
    connected, active = struct.unpack_from('<II', setup, 24)
    require(active == topology['activeUnknownCount'], 'setup_active_count')
    offset, count = table(setup, 2, 4, 96)
    mapping = list(struct.unpack_from('<'+str(count)+'I', setup, offset))
    require(mapping == [NONE if x.get('activeUnknownIndex') is None else x['activeUnknownIndex'] for x in topology['nodes']], 'setup_raw_active_map')
    po, pn = table(program, 8, 32)
    so, sn = table(program, 10, 1)
    pool = program[so:so+sn]
    node_offset, node_count = table(program, 9, 16)
    raw_count = struct.unpack_from('<I', program, 32)[0]
    require(raw_count == node_count == len(topology['nodes']), 'program_topology_raw_count')
    for index, node in enumerate(topology['nodes']):
        osdi_index, name_offset, name_bytes, is_flow = struct.unpack_from('<IIII', program, node_offset+16*index)
        require(osdi_index == index == integer(node['index']) and is_flow in (0, 1), 'program_topology_node_index')
        require(node['name'] == string(pool, name_offset, name_bytes), 'program_topology_node_name')
        require(type(node['isFlow']) is bool and node['isFlow'] == bool(is_flow), 'program_topology_node_flow')
    parameters = [struct.unpack_from('<6IQ', program, po+i*32) for i in range(pn)]
    names = [(string(pool, p[3], p[4]).casefold(), p[1], p[2]) for p in parameters]
    expected = {}
    for key, scope in (('modelParameters', 1), ('instanceParameters', 2)):
        for value in outer[key]:
            require(value['scope'] == ('model' if scope == 1 else 'instance'), 'parameter_scope')
            indices = [i for i, (name, sc, _) in enumerate(names) if name == value['name'].casefold() and sc == scope]
            require(len(indices) == 1, 'parameter_name_or_alias_unsupported')
            index = indices[0]
            require(index not in expected, 'duplicate_parameter')
            expected[index] = value
    fo, fn = table(setup, 0, 16, 96)
    ss, ns = table(setup, 3, 1, 96)
    setup_pool = setup[ss:ss+ns]
    found = set()
    for j in range(fn):
        index, given, value = struct.unpack_from('<IIQ', setup, fo+16*j)
        require(index < pn and index not in found and given in (0, 1), 'setup_fact_shape')
        found.add(index)
        require(bool(given) == (index in expected), 'setup_given_mismatch')
        if not given:
            require(value == 0, 'setup_nongiven_bits')
            continue
        fact, ty = expected[index], parameters[index][2]
        require({'real': 1, 'integer': 2, 'string': 4}.get(fact['type']) == ty, 'setup_fact_type')
        if ty == 1:
            require(value == bits(fact['value']), 'setup_real_fact')
        elif ty == 2:
            require(value == (int(fact['value']) & ((1<<64)-1)), 'setup_integer_fact')
        else:
            require(string(setup_pool, value & NONE, value >> 32) == fact['value'], 'setup_string_fact')
    require(set(expected) <= found, 'missing_explicit_setup_fact')
    simulation_offset, simulation_count = table(setup, 1, 24, 96)
    simulation_names = set()
    for j in range(simulation_count):
        name_offset, name_bytes, kind, given, value = struct.unpack_from('<IIIIQ', setup, simulation_offset+24*j)
        name = string(setup_pool, name_offset, name_bytes)
        require(name not in simulation_names and kind in (1, 2, 3, 4), 'simulation_fact_shape')
        simulation_names.add(name)
        require(given == 0 and value == 0, 'simulation_override_unsupported')
    return connected


_NUMBER = re.compile(r'([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)(meg|[tgkmunpf])?', re.I)


def number(token):
    match = _NUMBER.fullmatch(token)
    require(match is not None, 'unsupported_source_number:'+token)
    factors = {None: 1, 't': 1e12, 'g': 1e9, 'meg': 1e6, 'k': 1e3, 'm': 1e-3, 'u': 1e-6, 'n': 1e-9, 'p': 1e-12, 'f': 1e-15}
    result = float(match[1])*factors[match[2].casefold() if match[2] else None]
    return real(result)


def parse_source(data):
    """Deliberately bounded flat qualification grammar; unknown physics refuses."""
    try:
        text = data.decode('utf-8')
    except UnicodeError as error:
        raise Refusal('source_encoding') from error
    circuit = {key: [] for key in ('devices', 'resistors', 'capacitors', 'inductors', 'voltageSources', 'currentSources')}
    circuit.update(options={}, initialConditions={}, nodeSets={})
    seen, model_names = set(), set()
    lines = text.splitlines()
    for ordinal, original in enumerate(lines):
        if ordinal == 0 or not original.strip() or original.lstrip().startswith('*'):
            continue
        line = original.strip()
        require(not line.startswith('+'), 'source_continuation_unsupported')
        fields = line.split()
        command = fields[0].casefold()
        if command == '.end':
            continue
        if command == '.model':
            require(len(fields) == 3 and fields[2].casefold() == 'osdi', 'unsupported_model_source')
            name = fields[1].casefold()
            require(name not in model_names, 'duplicate_source_model')
            model_names.add(name)
        elif command == '.options':
            for field in fields[1:]:
                key, separator, value = field.partition('=')
                key = key.casefold()
                require(separator and key in ('temp', 'tnom', 'gmin', 'reltol', 'abstol', 'vntol', 'itl1',
                    'tranmaxaccepted', 'tranmaxattempts', 'tranmaxiterations', 'tranmaxscalars',
                    'tranmaxdimension', 'tranmaxwork', 'tranmaxbreakpoints'), 'unsupported_source_option')
                require(key not in circuit['options'], 'duplicate_source_option')
                circuit['options'][key] = number(value)
        elif command in ('.ic', '.nodeset'):
            target = circuit['initialConditions' if command == '.ic' else 'nodeSets']
            for field in fields[1:]:
                match = re.fullmatch(r'V\(([^()]+)\)=(.+)', field, re.I)
                require(match is not None, 'unsupported_initial_condition')
                name = match[1].casefold()
                require(name not in target, 'duplicate_initial_condition')
                target[name] = number(match[2])
        elif command == '.tran':
            require('transient' not in circuit and 3 <= len(fields) <= 6, 'transient_source_shape')
            uic = fields[-1].casefold() == 'uic'
            values = [number(x) for x in fields[1:-1] if uic] if uic else [number(x) for x in fields[1:]]
            require(len(values) in (2, 3, 4) and values[0] > 0 and values[1] > 0 and (len(values) < 3 or values[2] == 0), 'transient_source_range')
            circuit['transient'] = {'step': values[0], 'stop': values[1], 'uic': uic}
        elif command in ('.save', '.print'):
            # Presentation does not contribute an original MNA equation.
            continue
        elif command.startswith('.'):
            raise Refusal('unsupported_source_directive:'+command)
        else:
            require(command not in seen and len(fields) >= 3, 'duplicate_source_element')
            seen.add(command)
            if command.startswith('n'):
                require(len(fields) >= 3, 'osdi_instance_shape')
                circuit['devices'].append({'id': command, 'terminals': [x.casefold() for x in fields[1:-1]], 'modelName': fields[-1].casefold()})
                continue
            require(command[0] in 'rclvi' and len(fields) >= 4, 'unsupported_source_element:'+command)
            part = {'id': command, 'positive': fields[1].casefold(), 'negative': fields[2].casefold()}
            tail = ' '.join(fields[3:])
            if tail[:4].casefold() == 'pwl(':
                require(command[0] in 'vi' and tail.endswith(')'), 'unsupported_waveform')
                tokens = tail[4:-1].replace(',', ' ').split()
                require(tokens and len(tokens)%2 == 0, 'pwl_shape')
                values = [number(x) for x in tokens]
                points = list(zip(values[::2], values[1::2]))
                require(all(t >= 0 for t, _ in points) and all(a[0] < b[0] for a, b in zip(points, points[1:])), 'pwl_times')
                part.update(value=points[0][1], waveform=points)
            else:
                require(len(fields) == 4, 'unsupported_source_expression')
                part['value'] = number(fields[3])
            key = {'r': 'resistors', 'c': 'capacitors', 'l': 'inductors', 'v': 'voltageSources', 'i': 'currentSources'}[command[0]]
            circuit[key].append(part)
    require('transient' in circuit and circuit['devices'] and all(x['modelName'] in model_names for x in circuit['devices']), 'incomplete_source_circuit')
    require(circuit['options'].get('gmin') == 0, 'nonzero_or_missing_gmin_profile')
    return circuit


@dataclass(frozen=True)
class Model:
    name: str
    original: dict
    cold: dict
    program: bytes
    setup: bytes
    active_to_global: tuple
    raw_to_global: tuple


@dataclass(frozen=True)
class Decoded:
    record: dict
    execution: dict
    precision: dict
    circuit: dict
    models: tuple
    highs: tuple
    lows: tuple
    times: tuple
    intervals: tuple
    tolerances: tuple
    node_rows: dict
    branch_rows: dict
    configuration_binding: dict | None = None


def check_settings(settings, circuit, rows, node_rows, coordinates, count):
    require(settings['analysis'] == 'tran', 'settings_analysis')
    integer(settings['analysisIndex']); integer(settings['seed'])
    config = settings['transient']
    for name in ('stopTime', 'maxTimeStep', 'minTimeStep', 'lteTolerance'):
        require(real(config[name]) > 0, 'transient_positive_setting')
    require(config['preferredMethod'] in ('backwardEuler', 'trapezoidal') and type(config['useInitialConditions']) is bool, 'transient_method')
    require(bits(config['stopTime']) == bits(coordinates[-1]) == bits(circuit['transient']['stop']), 'stop_time_mismatch')
    require(config['useInitialConditions'] == circuit['transient']['uic'], 'initialization_mismatch')
    require(0 < real(config['shrinkFactor']) < 1 and config['minTimeStep'] <= config['maxTimeStep'], 'transient_range')
    integer(config['maxTimeStepReductions']); integer(config['gminSteppingThreshold'])
    require(config['gminSteppingThreshold'] > 0, 'gmin_threshold')
    for name in ('initialGmin', 'gminReductionFactor'):
        require(real(config[name]) > 0, 'gmin_setting')
    require(real(config['finalGmin']) >= 0 and config['gminReductionFactor'] > 1, 'gmin_range')
    require(integer(config['maximumGminSteps']) > 0, 'gmin_steps')
    if config.get('initialTimeStep') is not None:
        require(real(config['initialTimeStep']) > 0, 'initial_step')
    convergence = settings['convergence']
    for name in ('abstol', 'vntol', 'minDamping', 'opticalPowerTolerance'):
        require(real(convergence[name]) > 0, 'convergence_positive')
    require(real(convergence['reltol']) >= 0 and real(convergence['gmin']) == 0 and convergence['minDamping'] <= 1, 'convergence_range')
    require(integer(convergence['maxIterations']) > 0, 'newton_iterations')
    for name in ('abstol', 'vntol', 'reltol', 'gmin'):
        if name in circuit['options']:
            require(bits(convergence[name]) == bits(circuit['options'][name]), 'source_convergence_mismatch:'+name)
    for key, source_key in (('initialConditions', 'initialConditions'), ('nodeSets', 'nodeSets')):
        expected = {}
        for name, value in circuit[source_key].items():
            row = None if name in ('0', 'gnd') else node_rows.get(name)
            require(row is not None or (name in ('0', 'gnd') and value == 0), 'initial_node_missing')
            expected[row] = value
        actual = settings[key]
        require(len(actual) == len(expected) and len({x.get('row') for x in actual}) == len(actual), 'initial_conditions_shape')
        require(all(x.get('row') in expected and bits(x['value']) == bits(expected[x.get('row')]) for x in actual), 'initial_conditions_mismatch')
    limits = settings['numericalLimits']
    for key in ('maximumAcceptedSteps', 'maximumSolveAttempts', 'maximumNewtonIterations', 'maximumSavedScalars',
                'maximumMatrixDimension', 'maximumWorkUnits', 'maximumBreakpoints'):
        require(integer(limits[key]) > 0, 'numerical_limit')
    for source_key, setting_key in (
        ('tranmaxaccepted', 'maximumAcceptedSteps'), ('tranmaxattempts', 'maximumSolveAttempts'),
        ('tranmaxiterations', 'maximumNewtonIterations'), ('tranmaxscalars', 'maximumSavedScalars'),
        ('tranmaxdimension', 'maximumMatrixDimension'), ('tranmaxwork', 'maximumWorkUnits'),
        ('tranmaxbreakpoints', 'maximumBreakpoints')):
        if source_key in circuit['options']:
            value = circuit['options'][source_key]
            require(value.is_integer() and int(value) == limits[setting_key], 'source_numerical_limit_mismatch')
    if 'itl1' in circuit['options']:
        require(circuit['options']['itl1'] == convergence['maxIterations'], 'source_newton_limit_mismatch')
    require(count-1 <= limits['maximumAcceptedSteps'] and count*(len(rows)+1) <= limits['maximumSavedScalars'] and len(rows) <= limits['maximumMatrixDimension'], 'saved_limits_mismatch')
    for key in ('temperatureKelvin', 'nominalTemperatureKelvin'):
        require(real(settings[key]) > 0, 'settings_temperature')
    for source_key, setting_key in (('temp', 'temperatureKelvin'), ('tnom', 'nominalTemperatureKelvin')):
        if source_key in circuit['options']:
            require(bits(circuit['options'][source_key]+273.15) == bits(settings[setting_key]), 'source_temperature_mismatch')


def check_case(circuit, case, models):
    """Cross-bind recorded source equations to the preselected qualification input."""
    expected = case['input']['circuit']
    for key in ('resistors', 'capacitors', 'inductors', 'voltageSources', 'currentSources'):
        original = {x['id'].casefold(): x for x in expected.get(key, [])}
        actual = {x['id']: x for x in circuit[key]}
        require(set(original) == set(actual), 'source_manifest_elements:'+key)
        for name, part in actual.items():
            source = original[name]
            require(part['positive'] == source['positive'].casefold() and part['negative'] == source['negative'].casefold(), 'source_manifest_terminals')
            stimulus = case['input']['analysis'].get('stimulus')
            selected = stimulus and name == stimulus['sourceID'].casefold()
            if selected and stimulus.get('points'):
                points = [(x['timeSeconds'], x['value']) for x in stimulus['points']]
                if len(points) > 1:
                    require(part.get('waveform') == points, 'source_manifest_waveform')
                else:
                    require(bits(part['value']) == bits(points[0][1]), 'source_manifest_constant_stimulus')
            else:
                require('waveform' not in part and bits(part['value']) == bits(source['value']), 'source_manifest_value')
    original_devices = {x['id'].casefold(): x for x in expected['devices']}
    require(len(original_devices) == len(models), 'manifest_device_count')
    for model in models:
        outer = model.original
        source = original_devices.get(outer['modelName'].casefold())
        require(source is not None, 'manifest_model_binding')
        require(bits(source['temperatureKelvin']) == bits(outer['effectiveKelvin']), 'manifest_temperature')
        actual = { (x['scope'], x['name'].casefold()): (x['type'], x['value'])
                  for key in ('modelParameters', 'instanceParameters') for x in outer[key] }
        target = {(x['scope'], x['name'].casefold()): (x['value']['kind'], x['value'][x['value']['kind']]) for x in source['parameters']}
        require(actual == target, 'manifest_scoped_parameters')
        names = outer['rawNodeNames'][:source['connectedTerminalCount']]
        raw = model.raw_to_global
        require(model.cold['program']['topology']['activeUnknownCount'] > 0, 'manifest_topology')
        for index, name in enumerate(names):
            terminal = source['terminals'][name].casefold()
            row = next((x['row'] for x in case['_rows'] if x.get('sourceName', '').casefold() == terminal and x['kind'] == 'node'), None)
            require((terminal in ('0', 'gnd') and raw[index] is None) or (row is not None and raw[index] == row), 'manifest_terminal_mapping')


def check_model_schemas(models):
    for model in models:
        phase = model['phase']
        expected = {'op': (1, 'nativeOSDI.op.v1'), 'tran': (2, 'nativeOSDI.analysis.v2')}.get(phase)
        require(expected is not None and type(model['schemaVersion']) is int and
                (model['schemaVersion'], model['profile']) == expected, 'model_record_schema')


def _decode(record, manifest, case=None):
    version = record['schemaVersion']
    require((type(version) is int and version == 4) or
            (type(version) is dict and set(version) == {'major', 'minor', 'patch'} and
             all(type(version[key]) is int for key in version) and
             version == {'major': 4, 'minor': 0, 'patch': 0}), 'outer_schema')
    require(record['status'] == 'succeeded', 'incomplete_record')
    execution = record['osdiExecution']
    precision = execution['precision']
    require(type(execution['schemaVersion']) is int and execution['schemaVersion'] == 2 and
            execution['analysis'] == 'tran' and type(precision['schemaVersion']) is int and
            precision['schemaVersion'] == 1, 'precision_schema')
    require(precision['algorithmIdentity'] == ALGORITHM and precision['displayRepresentation'] == 'rounded-binary64' and bits(precision['endpointLowComponent']) == 0, 'precision_algorithm_context')
    require(digest(precision['configurationSHA256']) == record['configurationIdentity'] and digest(precision['sourceInputIdentity']) == record['sourceInputIdentity'], 'outer_identity_mismatch')
    budget = precision['executionBudget']
    for name in ('maximumNativeAllocationBytes', 'maximumLiveOwnedBytes', 'maximumTemporaryBytes', 'maximumHashedBytes', 'maximumEvidenceBytes'):
        require(integer(budget[name], (1<<63)-1) > 0, 'execution_budget')
    rows, columns = execution['rows'], execution['columns']
    dimension = len(rows)
    require(0 < dimension <= MAX_ROWS and [integer(x['row']) for x in rows] == list(range(dimension)), 'complete_row_map')
    require(len(columns) == dimension and all(x['compiledRow'] == i and x['unit'] == rows[i]['unit'] for i, x in enumerate(columns)), 'complete_column_map')
    require(len({x['name'] for x in columns}) == dimension, 'duplicate_columns')
    node_rows, branch_rows = {}, {}
    for row in rows:
        require((row['kind'] == 'node' and row['unit'] in ('V', 'K')) or (row['kind'] == 'branch' and row['unit'] == 'A'), 'row_nature')
        name = row.get('sourceName')
        require(isinstance(name, str) and name, 'row_name_missing')
        selected = node_rows if row['kind'] == 'node' else branch_rows
        require(name.casefold() not in selected, 'ambiguous_row_name')
        selected[name.casefold()] = row['row']
    times = [real(x) for x in execution['coordinates']]
    count = len(times)
    require(1 < count <= MAX_STEPS+1 and times[0] == 0 and all(a < b for a, b in zip(times, times[1:])), 'coordinate_schedule')
    require(execution['sweepUnit'] == 's' and execution.get('imaginary') is None and execution.get('noise') is None, 'transient_quantity')
    require([integer(x) for x in precision['coordinateBits']] == [bits(x) for x in times], 'coordinate_bits')
    size = count*dimension
    require(len(execution['real']) == len(precision['solutionLow']) == len(precision['highBits']) == len(precision['lowBits']) == size, 'paired_trace_shape')
    highs, lows = [], []
    for high, low, hb, lb in zip(execution['real'], precision['solutionLow'], precision['highBits'], precision['lowBits']):
        h, l = from_bits(hb), from_bits(lb)
        require(math.isfinite(h) and math.isfinite(l) and bits(high) == hb and bits(low) == lb, 'component_bits_mismatch')
        exact_pair(h, l)
        highs.append(h); lows.append(l)
    steps = execution['acceptedSteps']
    require(len(steps) == count-1 and steps[0]['method'] == 'backwardEuler', 'first_BE_and_step_count')
    intervals = []
    for index, step in enumerate(steps):
        t, h, l = real(step['timeSeconds']), real(step['timeStepSeconds']), real(step['timeStepLowComponent'])
        require(integer(step['timeSecondsBits']) == bits(t) and integer(step['timeStepBits']) == bits(h) and integer(step['timeStepLowBits']) == bits(l), 'accepted_component_bits')
        dt = exact_pair(h, l)
        require(t == times[index+1] and dt > 0 and dt == Fraction(times[index+1])-Fraction(times[index]), 'exact_accepted_interval')
        require(step['method'] in ('backwardEuler', 'trapezoidal'), 'accepted_method')
        previous = step.get('previousTimeStepSeconds')
        if previous is None:
            require(step['method'] == 'backwardEuler' and
                    all(step.get(x) is None for x in ('previousTimeStepLowComponent', 'previousTimeStepBits', 'previousTimeStepLowBits')), 'missing_previous_history')
        else:
            ph, pl = real(previous), real(step['previousTimeStepLowComponent'])
            require(integer(step['previousTimeStepBits']) == bits(ph) and integer(step['previousTimeStepLowBits']) == bits(pl), 'previous_interval_bits')
            require(index > 0 and exact_pair(ph, pl) == intervals[-1], 'previous_interval_history')
        intervals.append(dt)
    sources = precision['sources']
    require(len(sources['captures']) == len(sources['occurrences']) == 1, 'flat_source_profile')
    capture, occurrence = sources['captures'][0], sources['occurrences'][0]
    require(capture['key'] == occurrence['key'] == sources['rootKey'] and occurrence.get('parentOccurrenceID') is None, 'source_occurrence_binding')
    integer(occurrence['occurrenceID'])
    source_identity = artifact_identity(capture['reference'])
    data = canonical_bytes(capture['bytes'], min(MAX_SOURCE, source_identity['byteCount']))
    require(len(data) == source_identity['byteCount'] and sha(data) == source_identity['sha256'], 'source_bytes_identity')
    circuit = parse_source(data)
    check_settings(precision['settings'], circuit, rows, node_rows, times, count)
    op = execution.get('operatingPoint')
    use_ic = precision['settings']['transient']['useInitialConditions']
    require(precision['operatingPointRepresentation'] == ('absent-uic' if use_ic else 'binary64'), 'op_representation')
    require((use_ic and op is None) or (not use_ic and isinstance(op, list) and len(op) == dimension), 'op_presence')
    if op is not None:
        require(all(bits(x) == bits(highs[i]) for i, x in enumerate(op)) and all(bits(x) == 0 for x in lows[:dimension]), 'initial_binary64_OP')
    else:
        for name, value in circuit['initialConditions'].items():
            if name not in ('0', 'gnd'):
                row = node_rows[name]
                require(Fraction(highs[row])+Fraction(lows[row]) == Fraction(value), 'UIC_initial_coordinate')
    policy = precision['equationPolicy']
    require(len(policy) == dimension and [x['row'] for x in policy] == list(range(dimension)), 'equation_policy_shape')
    tolerances = []
    for row, value in zip(rows, policy):
        expected = 'electricalFlow' if row['kind'] == 'branch' else 'thermalPotential' if row['unit'] == 'K' else 'electricalPotential'
        require(value['kind'] == expected and real(value['variableAbsoluteTolerance']) > 0 and real(value['equationAbsoluteTolerance']) > 0, 'equation_policy_kind')
        tolerance = real(value['equationAbsoluteTolerance'])
        if case is not None:
            unit = {'electricalFlow': 'V', 'electricalPotential': 'A', 'thermalPotential': 'W'}[expected]
            ceiling = case['input']['circuit']['policy']['equationAbsoluteTolerances'][unit]
        else:
            require(expected != 'thermalPotential', 'thermal_qualification_policy_required')
            ceiling = circuit['options']['vntol' if expected == 'electricalFlow' else 'abstol']
        require(tolerance <= ceiling, 'equation_gate_relaxed')
        tolerances.append(Fraction(tolerance))
    original_models = record['osdiModels']
    check_model_schemas(original_models)
    outer = {x['instanceName'].casefold(): x for x in original_models if x['phase'] == 'tran'}
    require(len(outer) == len([x for x in original_models if x['phase'] == 'tran']), 'duplicate_phase_model')
    require(all(x['phase'] in ('op', 'tran') for x in original_models), 'unexpected_model_phase')
    op_models = [x for x in original_models if x['phase'] == 'op']
    require((use_ic and not op_models) or (not use_ic and {x['instanceName'].casefold() for x in op_models} == set(outer) and len(op_models) == len(outer)), 'ordinary_OP_phase')
    for value in op_models:
        original = outer[value['instanceName'].casefold()]
        require(value['completedPointCount'] == 1 and all(value[key] == original[key] for key in ('artifact', 'descriptorIndex', 'rawNodeGlobalRows', 'rawNodeNames', 'modelParameters', 'instanceParameters', 'effectiveKelvin')), 'ordinary_OP_binding')
    require(len(outer) == len(precision['coldModels']) and 0 < len(outer) <= 16, 'cold_model_count')
    source_instances = {x['id']: x for x in circuit['devices']}
    require(set(source_instances) == set(outer), 'source_instance_binding')
    qualified = {x['sha256']: x for x in manifest['models']}
    models, owned_rows = [], set()
    for cold in precision['coldModels']:
        name = cold['instanceName'].casefold()
        require(name in outer and all(x.name != name for x in models), 'cold_instance_identity')
        original = outer[name]
        value = cold['program']
        model_identity = artifact_identity(value['modelReference'])
        require(value['modelReference'] == original['artifact'] and model_identity['sha256'] in qualified, 'model_artifact_binding')
        qualification = qualified[model_identity['sha256']]
        require(model_identity['byteCount'] == qualification['byteCount'] and value['descriptorIndex'] == original['descriptorIndex'] == qualification['descriptorIndex'], 'model_descriptor_binding')
        require(original['expectedDescriptorName'] == qualification['descriptorName'], 'model_descriptor_name')
        for option in cold['options'].values():
            require(integer(option) > 0, 'option_type')
        integer(cold['precisionBits'])
        require(artifact_identity(cold['workerReference']) == {x: manifest['worker'][x] for x in ('sha256', 'byteCount')}, 'worker_binding')
        require(cold['numericProfileSHA256'] == manifest['numericProfileSHA256'] and cold['precisionBits'] == manifest['precisionBits'] and cold['options'] == manifest['options'], 'precision_profile_options')
        program = canonical_bytes(value['programBytes'], min(cold['options']['maximumProgramBytes'], 64*1024*1024))
        setup = canonical_bytes(value['setupBytes'], min(cold['options']['maximumMappingBytes'], 64*1024*1024))
        require(sha(program) == digest(value['programSHA256']) == qualification['program']['sha256'] and sha(setup) == digest(value['setupSHA256']), 'program_setup_identity')
        require(value['semanticProfileSHA256'] == manifest['semanticProfileSHA256'] == program[40:72].hex(), 'semantic_profile_identity')
        topology = value['topology']
        nodes, active_count = topology['nodes'], topology['activeUnknownCount']
        require(topology['stateCount'] == 0 and len(nodes) == len(original['rawNodeNames']) and 0 < active_count <= MAX_ROWS, 'model_topology_shape')
        require([x['index'] for x in nodes] == list(range(len(nodes))) and [x['name'] for x in nodes] == original['rawNodeNames'], 'raw_node_identity')
        require([x['units'] for x in nodes] == original['rawNodeUnits'] and [x['residualUnits'] for x in nodes] == original['rawEquationUnits'], 'raw_nature_identity')
        connected = check_setup(program, setup, original, topology)
        source = source_instances[name]
        require(source['modelName'] == original['modelName'].casefold() and connected == len(source['terminals']), 'source_model_terminals')
        require(original['completedPointCount'] == count and original.get('previousState', []) == [], 'model_completion_state')
        raw_map = original['rawNodeGlobalRows']
        require(len(raw_map) == len(nodes), 'raw_global_shape')
        active_map = [NONE]*active_count
        external_active, external_global = set(), set()
        for index, (node, row) in enumerate(zip(nodes, raw_map)):
            require(row is None or (type(row) is int and 0 <= row < dimension and rows[row]['unit'] == node['units']), 'raw_global_nature')
            local = node.get('activeUnknownIndex')
            if local is None:
                require(row is None, 'local_ground_mapping')
            else:
                require(type(local) is int and 0 <= local < active_count, 'local_active_axis')
                if active_map[local] == NONE:
                    active_map[local] = row
                else:
                    require(active_map[local] == row, 'alias_global_consistency')
            if index < connected:
                terminal = source['terminals'][index]
                expected_row = None if terminal in ('0', 'gnd') else node_rows.get(terminal, NONE)
                require(row == expected_row and expected_row != NONE, 'source_terminal_global_mapping')
                if local is not None:
                    external_active.add(local)
                if row is not None:
                    external_global.add(row)
        require(NONE not in active_map, 'active_coordinate_coverage')
        for local, row in enumerate(active_map):
            if local not in external_active:
                require(row is not None and row not in external_global and row not in owned_rows, 'private_coordinate_alias')
                owned_rows.add(row)
        models.append(Model(name, original, cold, program, setup, tuple(active_map), tuple(raw_map)))
    covered = {row for model in models for row in model.raw_to_global if row is not None}
    for key in ('resistors', 'capacitors', 'inductors', 'voltageSources', 'currentSources'):
        for part in circuit[key]:
            for terminal in (part['positive'], part['negative']):
                if terminal not in ('0', 'gnd'):
                    require(terminal in node_rows, 'external_node_unmapped')
                    covered.add(node_rows[terminal])
            if key in ('inductors', 'voltageSources'):
                require(part['id'] in branch_rows, 'external_branch_unmapped')
                covered.add(branch_rows[part['id']])
    require(covered == set(range(dimension)), 'unexplained_global_coordinate')
    if case is not None:
        augmented = dict(case)
        augmented['_rows'] = rows
        check_case(circuit, augmented, models)
    return Decoded(record, execution, precision, circuit, tuple(models), tuple(highs), tuple(lows), tuple(times), tuple(intervals), tuple(tolerances), node_rows, branch_rows)


def verify_configuration(decoded):
    """Verify the Native-owned cold commitment from independently decoded facts."""
    import binding
    return binding.verify(decoded)


def decode_structure(record, manifest, case=None):
    """Structural admission only; canonical Native commitment is a separate gate."""
    try:
        return _decode(record, manifest, case)
    except Refusal:
        raise
    except (KeyError, TypeError, IndexError, struct.error, OverflowError) as error:
        raise Refusal('missing_or_malformed_field:'+str(error)) from error


def decode(record, manifest, case=None):
    decoded = decode_structure(record, manifest, case)
    details = verify_configuration(decoded)
    return replace(decoded, configuration_binding=details)
