#!/usr/bin/env python3
"""Measure the actual MOS boundary in fresh release processes with calibrated copy APIs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
CORE = HERE.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--scratch-path', type=Path, default=HERE / '.build')
    parser.add_argument('--config-path', type=Path)
    parser.add_argument('--samples', type=int, default=5)
    parser.add_argument('--releases', nargs='+', choices=['level1', 'bsim3', 'bsim4', 'bsim45'],
                        default=['level1', 'bsim3', 'bsim4', 'bsim45'])
    args = parser.parse_args()
    if not 1 <= args.samples <= 20:
        parser.error('samples must be in 1...20')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, TOOLCHAINS='org.swift.640202609131a')
    report = {'status': 'running', 'commands': [], 'results': {}, 'sourceSHA256': {},
              'toolchain': 'swift-6.4.0-RELEASE', 'scope': 'Native CPU release MOS boundary; copy API entries, not all physical traffic'}
    for base in [CORE / 'Sources', HERE]:
        for path in sorted(base.rglob('*')):
            if path.is_file() and '.build' not in path.parts and path.suffix in ('.swift', '.c', '.h', '.inc', '.py'):
                report['sourceSHA256'][str(path.relative_to(CORE))] = digest(path)
    lock = HERE / 'Package.resolved'
    old_lock = lock.read_bytes() if lock.exists() else None
    old_metadata = lock.stat() if lock.exists() else None

    def save():
        (out / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')

    def run(label, command, timeout=60, extra_env=None):
        start = time.monotonic()
        process = subprocess.Popen(list(map(str, command)), cwd=HERE,
            env=env if extra_env is None else dict(env, **extra_env),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                stdout, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate(timeout=5)
        finally:
            if timed_out:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        (out / (label + '.stdout.log')).write_bytes(stdout)
        (out / (label + '.stderr.log')).write_bytes(stderr)
        report['commands'].append({'label': label, 'command': list(map(str, command)),
            'timeoutSeconds': timeout, 'seconds': time.monotonic() - start,
            'exitCode': process.returncode, 'timedOut': timed_out})
        save()
        if timed_out or process.returncode:
            raise RuntimeError(label + ': ' + (stdout + stderr).decode(errors='replace')[-3000:])
        print(label, 'passed', flush=True)
        return stdout.decode()

    try:
        run('toolchain', ['xcrun', 'swift', '--version'], 30)
        common = ['--package-path', HERE, '--scratch-path', args.scratch_path.resolve()]
        if args.config_path:
            common += ['--config-path', args.config_path.resolve()]
        command = ['xcrun', 'swift', 'build'] + common + ['-c', 'release', '-j', '6', '--product', 'MOSPerformanceProbe']
        run('build-release', command, 600)
        binary_dir = run('binary-path', command + ['--show-bin-path'], 30).strip()
        executable = Path(binary_dir) / 'MOSPerformanceProbe'
        library = out / 'libMOSMemoryInterposer.dylib'
        run('build-interposer', ['xcrun', 'clang', '-std=c11', '-O2', '-fPIC', '-dynamiclib',
            '-fno-builtin', HERE / 'interposer/AllocationInterposer.c', '-o', library], 30)
        report['executableSHA256'] = digest(executable)
        report['interposerSHA256'] = digest(library)
        for release in dict.fromkeys(args.releases):
            cold = [json.loads(run(f'cold-{release}-{i}', [executable, 'cold', release, '1']))
                    for i in range(args.samples)]
            reuse = json.loads(run('reuse-' + release, [executable, 'reuse', release, str(args.samples)]))
            expected = cold[0]['samples'][0]['resultSignature']
            measured = {}
            for mode in ['cold', 'reuse']:
                value = json.loads(run('memory-' + mode + '-' + release,
                    [executable, mode, release, '1' if mode == 'cold' else str(args.samples)],
                    extra_env={'DYLD_INSERT_LIBRARIES': str(library), 'MOS_ALLOCATION_PROBE': '1'}))
                calibration = value['allocationAPI']['calibration']
                assert value['allocationAPI']['calibrationPassed']
                assert calibration['mallocCalls'] == calibration['freeCalls'] == 1
                assert calibration['requestedBytes'] == 257 and calibration['copiedBytes'] == 101
                assert calibration['copyCalls'] == 5
                assert value['allocationAPI']['parseAndCompile']['copiedBytes'] > 0
                measured[mode] = value
            all_samples = [c['samples'][0] for c in cold] + reuse['samples']
            all_samples += [row for value in measured.values() for row in value['samples']]
            assert all(row['resultSignature'] == expected and row['completedPoints'] == 5 for row in all_samples)
            assert all(all(v == 0 for v in row['downstreamResolutionWorkDelta'].values()) for row in all_samples)
            assert all(all(v == 0 for v in row['sourceResourceWorkDeltaDuringAnalysis'].values()) for row in all_samples)
            assert all(len(row['mosReceipts']) == 8 and all(r['coldSetupCount'] == 1 for r in row['mosReceipts']) for row in all_samples)
            report['results'][release] = {'cold': cold, 'reuse': reuse, 'memoryAPI': measured,
                'coldMedianMilliseconds': statistics.median(c['samples'][0]['totalSeconds'] * 1000 for c in cold),
                'reuseMedianMilliseconds': statistics.median(row['totalSeconds'] * 1000 for row in reuse['samples'])}
            save()
        assert all(digest(CORE / path) == expected for path, expected in report['sourceSHA256'].items())
        report['status'] = 'passed'
        report['limits'] = ['Copy API arguments/counts include nested API entries; inlined/private loops are outside coverage.',
            'Instrumented timing is excluded from cold/reuse timing summaries.',
            'No statistical speedup claim, GPU/portable numerical or process-accuracy qualification.']
    except BaseException as error:
        report['status'] = 'failed'
        report['failure'] = str(error)
        raise
    finally:
        if old_lock is None:
            lock.unlink(missing_ok=True)
        else:
            lock.write_bytes(old_lock)
            os.chmod(lock, old_metadata.st_mode & 0o7777)
            os.utime(lock, ns=(old_metadata.st_atime_ns, old_metadata.st_mtime_ns))
        report['callerLockPreserved'] = (not lock.exists()) if old_lock is None else lock.read_bytes() == old_lock
        save()


if __name__ == '__main__':
    main()
