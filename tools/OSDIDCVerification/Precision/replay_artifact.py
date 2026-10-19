#!/usr/bin/env python3
"""Replay complete paired artifacts through the frozen independent C point oracle."""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import struct
import tempfile
import time

import artifact as a
import binding
import driver
import trajectory as t
import verify


def verify_engine(build_path):
    build, identity = a.strict_json(build_path)
    a.require(build['status'] == 'passed', 'oracle_build_status')
    for item in build['inputs']:
        record = item['snapshot']
        a.require(driver.identity(record['path'])['sha256'] == record['sha256'], 'oracle_source_identity')
    for record in [build['binary'], *build['arithmeticLibraries'], *build['arithmeticHeaders']]:
        a.require(driver.identity(record['path'])['sha256'] == record['sha256'], 'oracle_runtime_identity')
    return Path(build['binary']['path']), identity


def point(binary, program, setup, vectors, contexts, directory, deadline):
    """One bounded independent child. Every exceptional path kills and reaps it."""
    remaining = deadline-time.monotonic()
    a.require(remaining > 0, 'trajectory_timeout')
    timeout = min(30.0, remaining)
    a.require(shutil.disk_usage(directory).free >= 64*1024*1024, 'validation_output_reserve')
    request = directory/'points.bin'
    request.write_bytes(driver.points_bytes(vectors, contexts))
    def limits():
        resource.setrlimit(resource.RLIMIT_CPU, (30, 30))
        resource.setrlimit(resource.RLIMIT_FSIZE, (4*1024*1024, 4*1024*1024))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    started = time.monotonic()
    with (directory/'stdout.json').open('xb') as stdout, (directory/'stderr.txt').open('xb') as stderr:
        child = subprocess.Popen([str(binary), str(program), str(setup), str(request), '512', '100000000'],
                                 stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=limits,
                                 env={'PATH': '/usr/bin:/bin'})
        try:
            code = child.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(child.pid, 9)
            except ProcessLookupError:
                pass
            child.wait()
            raise
    a.require(code == 0, 'independent_point_refused')
    output, output_identity = a.strict_json(directory/'stdout.json', 4*1024*1024)
    a.require(output['status'] == 'passed', 'independent_point_incomplete')
    return output, {'seconds': time.monotonic()-started, 'work': output['work'],
                    'outputSHA256': output_identity['sha256'], 'outputBytes': output_identity['byteCount'],
                    'pointInputSHA256': a.sha(request.read_bytes()),
                    'stderrSHA256': a.sha((directory/'stderr.txt').read_bytes())}


def point_interval(value):
    for endpoint in ('lowerBinary', 'upperBinary'):
        item = value[endpoint]
        exponent, significand = item['exponent'], item['significand']
        a.require(type(exponent) is int and abs(exponent) <= 8192, 'oracle_exponent_profile')
        a.require(isinstance(significand, str) and 0 < len(significand.lstrip('-')) <= 512 and
                  all(x in '01' for x in significand.lstrip('-')), 'oracle_significand_profile')
    return verify.enclosure(value)


def external_circuit(circuit, time_value):
    result = {}
    for key in ('resistors', 'capacitors', 'inductors', 'voltageSources', 'currentSources'):
        result[key] = []
        for original in circuit[key]:
            part = dict(original)
            if 'waveform' in part:
                points = part.pop('waveform')
                stimulus = {'sourceID': part['id'], 'points': [{'timeSeconds': t0, 'value': v} for t0, v in points]}
                part['value'] = t.waveform_value(part, stimulus, time_value)
            result[key].append(part)
    return result


def directed_dyadic(value, upward, precision=512):
    """Exact integer arithmetic rounds a rational outward to a bounded significand."""
    value = Fraction(value)
    if value == 0:
        return Fraction(0)
    magnitude = abs(value)
    exponent = magnitude.numerator.bit_length()-magnitude.denominator.bit_length()
    if magnitude < Fraction(2)**exponent:
        exponent -= 1
    quantum = Fraction(2)**(exponent-precision+1)
    scaled = value/quantum
    rounded = -(-scaled.numerator//scaled.denominator) if upward else scaled.numerator//scaled.denominator
    return rounded*quantum


def bounded_history(values):
    return [t.Interval(directed_dyadic(value.lower, False), directed_dyadic(value.upper, True)) for value in values]


def summary_number(value):
    return str(directed_dyadic(value, True))


def write_final_receipt(path, receipt):
    data = (json.dumps(receipt, indent=2, allow_nan=False)+'\n').encode()
    a.require(len(data) <= 8*1024*1024, 'final_receipt_limit')
    with Path(path).open('xb') as stream:
        stream.write(data)


def replay(decoded, binary, output, deadline):
    """Caller assumes the complete independent artifact admission has succeeded."""
    dimension = len(decoded.execution['rows'])
    model_paths = []
    models_directory = output/'models'
    models_directory.mkdir()
    for index, model in enumerate(decoded.models):
        program, setup = models_directory/(str(index)+'.program'), models_directory/(str(index)+'.setup')
        program.write_bytes(model.program); setup.write_bytes(model.setup)
        model_paths.append((program, setup))
    previous_iq = [t.ZERO]*dimension
    summaries, maximum, calls = [], Fraction(0), 0
    for index, (step, interval) in enumerate(zip(decoded.execution['acceptedSteps'], decoded.intervals)):
        previous = [Fraction(h)+Fraction(l) for h, l in zip(decoded.highs[index*dimension:(index+1)*dimension], decoded.lows[index*dimension:(index+1)*dimension])]
        current = [Fraction(h)+Fraction(l) for h, l in zip(decoded.highs[(index+1)*dimension:(index+2)*dimension], decoded.lows[(index+1)*dimension:(index+2)*dimension])]
        now = Fraction(decoded.times[index+1])
        circuit = external_circuit(decoded.circuit, now)
        f, dq = t.assemble_external(circuit, decoded.node_rows, decoded.branch_rows, current, previous, now, None)
        model_summaries = []
        for model_index, (model, paths) in enumerate(zip(decoded.models, model_paths)):
            vectors = []
            for point_index, components in ((index+1, decoded.highs), (index+1, decoded.lows), (index, decoded.highs), (index, decoded.lows)):
                vectors.append([0.0 if row is None else components[point_index*dimension+row] for row in model.active_to_global])
            contexts = [{'mode': 2, 'high': decoded.times[index+1], 'low': 0.0},
                        {'mode': 3 if index == 0 else 2, 'high': decoded.times[index], 'low': 0.0}]
            temporary = Path(tempfile.mkdtemp(prefix='pair-', dir=output))
            try:
                evaluated, receipt = point(binary, *paths, vectors, contexts, temporary, deadline)
                a.require(len(evaluated['rows']) == len(model.raw_to_global) and [x['index'] for x in evaluated['rows']] == list(range(len(model.raw_to_global))), 'oracle_raw_shape')
                fs, qs = [], []
                for row in evaluated['rows']:
                    fl, fh = point_interval(row['F']); ql, qh = point_interval(row['deltaQ'])
                    fs.append(t.Interval(fl, fh)); qs.append(t.Interval(ql, qh))
                t.map_model_rows(f, dq, model.raw_to_global, fs, qs)
                calls += 1
                model_summaries.append({'modelIndex': model_index, 'work': receipt['work'],
                                        'inputSHA256': receipt['pointInputSHA256'], 'outputSHA256': receipt['outputSHA256']})
            except BaseException:
                retained = output/('failed-pair-'+str(index)+'-'+str(model_index))
                temporary.rename(retained)
                raise
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
        iq, residuals, merit = t.accepted_step(f, dq, previous_iq, interval, step['method'], decoded.tolerances)
        maximum = max(maximum, merit)
        summary = {'index': index, 'timeSeconds': decoded.times[index+1], 'method': step['method'],
                   'timeStepExact': str(interval), 'maximumNormalizedResidualUpper': summary_number(merit),
                   'models': model_summaries}
        summaries.append(summary)
        if merit > 1:
            summary['residualBounds'] = [[str(directed_dyadic(x.lower, False)), str(directed_dyadic(x.upper, True))] for x in residuals]
            driver.write_json(output/'failed-residual.json', summary)
            raise a.Refusal('original_equation_gate_rejected:step='+str(index))
        previous_iq = bounded_history(iq)
        a.require(time.monotonic() <= deadline, 'trajectory_timeout')
    return {'acceptedSteps': len(summaries), 'pointCalls': calls,
            'maximumNormalizedResidualUpper': summary_number(maximum), 'steps': summaries,
            'initializationQContext': 'TRAN|IC|STATIC', 'laterQContext': 'TRAN',
            'scope': 'Complete saved paired trajectory at its actual accepted intervals/methods; no unrelated fixed-grid comparison.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', required=True)
    parser.add_argument('--precision-manifest', required=True)
    parser.add_argument('--oracle-build', required=True)
    parser.add_argument('--analysis-manifest')
    parser.add_argument('--case-id')
    parser.add_argument('--output', required=True)
    parser.add_argument('--timeout-seconds', type=float, default=300)
    args = parser.parse_args()
    a.require(0 < args.timeout_seconds <= 3600, 'caller_timeout_profile')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    receipt = {'schema': 'corespice.independent-paired-trajectory.v1', 'status': 'failed',
               'limits': {'maximumArtifactBytes': a.MAX_JSON, 'maximumRows': a.MAX_ROWS,
                          'maximumAcceptedSteps': a.MAX_STEPS, 'wallSeconds': args.timeout_seconds,
                          'maximumConcurrentChildren': 1, 'pointPrecisionBits': 512,
                          'acceptedHistorySignificantBits': 512, 'maximumReceiptBytes': 8*1024*1024,
                          'outputReserveBytes': 128*1024*1024}}
    try:
        a.require(shutil.disk_usage(output).free >= 128*1024*1024, 'trajectory_output_reserve')
        record, artifact_identity = a.strict_json(args.artifact)
        manifest, manifest_identity = a.strict_json(args.precision_manifest)
        binary, build_identity = verify_engine(args.oracle_build)
        case = None
        a.require(bool(args.analysis_manifest) == bool(args.case_id), 'analysis_manifest_case_pair')
        if args.analysis_manifest:
            analysis, analysis_identity = a.strict_json(args.analysis_manifest)
            cases = [x for x in analysis['cases'] if x['id'] == args.case_id]
            a.require(len(cases) == 1 and cases[0]['kind'] == 'transient', 'analysis_case')
            case = cases[0]
            receipt['analysisManifest'] = analysis_identity
            receipt['caseID'] = args.case_id
        receipt.update(artifact=artifact_identity, precisionManifest=manifest_identity, oracleBuild=build_identity)
        decoded = a.decode(record, manifest, case)
        receipt['configurationBinding'] = decoded.configuration_binding
        receipt['result'] = replay(decoded, binary, output, started+args.timeout_seconds)
        receipt['status'] = 'passed'
    except (ValueError, OSError, subprocess.SubprocessError, TimeoutError, KeyError, TypeError, IndexError, OverflowError, struct.error) as error:
        receipt['failure'] = {'type': type(error).__name__, 'reason': str(error)}
    finally:
        snapshots = output/'tool-snapshots'
        snapshots.mkdir()
        receipt['tools'] = []
        for source in (Path(__file__), Path(a.__file__), Path(binding.__file__), Path(t.__file__), Path(driver.__file__), Path(verify.__file__)):
            target = snapshots/source.name
            shutil.copyfile(source, target)
            receipt['tools'].append(driver.identity(target))
        receipt['seconds'] = time.monotonic()-started
        write_final_receipt(output/'receipt.json', receipt)
    print(json.dumps({'status': receipt['status'], 'receipt': str(output/'receipt.json'), 'seconds': receipt['seconds']}))
    if receipt['status'] != 'passed':
        raise SystemExit(2)


if __name__ == '__main__':
    main()
