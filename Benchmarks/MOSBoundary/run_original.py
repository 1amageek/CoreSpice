#!/usr/bin/env python3
"""Measure the unchanged Sky130 public test path with existing calibrated hooks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

HERE = Path(__file__).resolve().parent
CORE = HERE.parents[1]
ROWS = ['nfetTT', 'nfetFF', 'nfetSS', 'pfetTT', 'rfTT', 'esdTT']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, TOOLCHAINS='org.swift.640202609131a')
    report = {'status': 'running', 'commands': [], 'sourceSHA256': {},
              'scope': 'Native CPU release exact-source six-row test child; includes test/audit/runtime overhead',
              'limitations': ['API-entry counters exclude inline copies/private loops/zone APIs; nested entries may be counted.',
                              'Requested bytes, RSS highwater and logical resource reservations are distinct.',
                              'One sample per mode is an observation, not a statistical speedup claim.']}
    sources = list((CORE / 'Sources').rglob('*')) + list((CORE / 'Tests/CoreSpiceNativeExecutionTests').glob('*.swift'))
    sources += list(HERE.rglob('*.c')) + [Path(__file__)]
    for path in sources:
        if path.is_file() and path.suffix in ('.swift', '.c', '.h', '.inc', '.py'):
            report['sourceSHA256'][str(path.relative_to(CORE))] = hashlib.sha256(path.read_bytes()).hexdigest()

    def save():
        (out / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')

    def run(label, command, extra=None):
        start = time.monotonic()
        with (out / (label + '.log')).open('w') as log:
            process = subprocess.Popen(list(map(str, command)), cwd=CORE, env=dict(env, **(extra or {})),
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                code = 124
        report['commands'].append({'label': label, 'command': list(map(str, command)),
                                   'exitCode': code, 'seconds': time.monotonic() - start})
        save()
        if code:
            raise RuntimeError(label + ': ' + (out / (label + '.log')).read_text()[-3000:])
        print(label, 'passed', flush=True)

    try:
        run('build-release-tests', ['xcrun', 'swift', 'build', '-c', 'release', '--force-resolved-versions',
            '--disable-xctest', '-Xswiftc', '-enable-testing', '-j', '3', '--product', 'CoreSpiceNativeExecutionTests'])
        interposer = out / 'libMOSMemoryInterposer.dylib'
        observer = out / 'libMOSProcessObserver.dylib'
        run('build-interposer', ['xcrun', 'clang', '-std=c11', '-O2', '-fPIC', '-dynamiclib', '-fno-builtin',
                                HERE / 'interposer/AllocationInterposer.c', '-o', interposer])
        # Calibration calls must originate outside the interposer image for dyld to observe them.
        run('build-observer', ['xcrun', 'clang', '-std=c11', '-O2', '-fPIC', '-dynamiclib', '-fno-builtin',
                              HERE / 'Sources/NativeHeapMetrics/NativeHeapMetrics.c',
                              HERE / 'OriginalSourceProcess/ProcessObserver.c',
                              '-I' + str(HERE / 'Sources/NativeHeapMetrics/include'), '-o', observer])
        helper = Path.home() / 'Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper'
        bundle = CORE / '.build/out/Products/Release/CoreSpiceNativeExecutionTests.xctest/Contents/MacOS/CoreSpiceNativeExecutionTests'
        report['testBinarySHA256'] = hashlib.sha256(bundle.read_bytes()).hexdigest()
        report['interposerSHA256'] = hashlib.sha256(interposer.read_bytes()).hexdigest()
        report['observerSHA256'] = hashlib.sha256(observer.read_bytes()).hexdigest()
        base_env = {'DYLD_FRAMEWORK_PATH': '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks',
                    'DYLD_LIBRARY_PATH': '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib',
                    'MOS_ORIGINAL_SKY130_ROOT': str(args.root.resolve())}
        results = {}
        for mode in ['uninstrumented', 'instrumented']:
            directory = out / mode
            directory.mkdir()
            extra = dict(base_env, MOS_ORIGINAL_SKY130_PROOF_DIRECTORY=str(directory))
            if mode == 'instrumented':
                extra.update(DYLD_INSERT_LIBRARIES=str(interposer) + ':' + str(observer),
                             MOS_PROCESS_METRICS_PATH=str(out / 'process-metrics.json'))
            run(mode, [helper, '--test-bundle-path', bundle, '--testing-library', 'swift-testing',
                       '--filter', 'Sky130OriginalExecutionTests'], extra)
            assert 'Test run with 2 tests in 1 suite passed' in (out / (mode + '.log')).read_text()
            results[mode] = {row: json.loads((directory / (row + '.json')).read_text()) for row in ROWS}
        for row in ROWS:
            original, measured = results['uninstrumented'][row], results['instrumented'][row]
            for key in ['sources', 'selectedModels', 'dc', 'ac', 'transient', 'noise', 'independentDifferentialProbe',
                        'evaluationSteps', 'randomDraws', 'completedAnalyses', 'numericalConditions', 'preparationImplementations']:
                assert original[key] == measured[key], (row, key)
            assert original['completedAnalyses'] == ['dc', 'ac', 'transient', 'noise']
        metrics = json.loads((out / 'process-metrics.json').read_text())
        assert metrics['status'] == 0 and metrics['calibrationPassed']
        assert metrics['mallocCalls'] > 0 and metrics['requestedBytes'] > 0
        assert metrics['copyCalls'] > 0 and metrics['copiedBytes'] > 0
        assert metrics['processPeakResidentBytes'] > 0
        for relative, digest in report['sourceSHA256'].items():
            assert hashlib.sha256((CORE / relative).read_bytes()).hexdigest() == digest, relative
        report.update(status='passed', processMetrics=metrics, rows=ROWS, numericalSignaturesEqual=True)
    except BaseException as error:
        report.update(status='failed', failure=str(error))
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
