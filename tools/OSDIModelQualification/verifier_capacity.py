#!/usr/bin/env python3
"""Bind a new bounded candidate verifier without replacing historical references."""
from argparse import ArgumentParser, Namespace
from contextlib import redirect_stdout
from pathlib import Path
import copy
import importlib.util
import io
import json
import shutil
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('dynamic', Path(__file__).with_name('dynamic.py'))
D = importlib.util.module_from_spec(spec)
spec.loader.exec_module(D)


def capture(args):
    D.guard()
    parent_record = {'path': str(args.manifest.resolve()), 'sha256': args.manifest_sha256}
    D.FAMILIES.checked_file(parent_record)
    parent = D.read_analysis_json(args.manifest)
    for row in [parent['oracle'], parent['compiler'], *parent['libraries']]:
        D.FAMILIES.checked_file(row)
    for row in parent['sources']:
        D.FAMILIES.checked_file({'path': row['snapshotPath'], 'sha256': row['sha256']})
    old_source = next(row for row in parent['sources'] if row['name'] == 'analysis_oracle.c')
    tool = D.HERE.parent / 'OSDIDCVerification'
    before = Path(old_source['snapshotPath']).read_text()
    after = (tool / 'analysis_oracle.c').read_text()
    assert before.replace('MAX_STEPS=256', 'MAX_STEPS=1000').replace(
        'ftell(stream)>1024*1024', 'ftell(stream)>8*1024*1024') == after
    output = args.output.resolve();output.mkdir(parents=True, exist_ok=False)
    snapshots = output / 'input-snapshots';snapshots.mkdir()
    shutil.copyfile(args.manifest, snapshots / 'parent-manifest.json')
    sources = []
    for path in (tool / 'analysis_oracle.c', tool / 'oracle.c', tool / 'osdi_0_4.h',
                 D.HERE / 'dynamic.py', Path(__file__).resolve()):
        destination = snapshots / path.name;shutil.copyfile(path, destination)
        sources.append({'name': path.name, 'sourcePath': str(path), 'snapshotPath': str(destination),
                        'sha256': D.BASE.digest(destination)})
    assert D.BASE.digest(snapshots / 'osdi_0_4.h') == D.BASE.HEADER_SHA
    clang = Path(shutil.which(args.clang)).resolve();commands = []
    D.run([clang, '--version'], output, 'clang-version', commands)
    binary = output / 'analysis-verifier'
    flags = ['-std=c17', '-O1', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function']
    D.run([clang, *flags, '-fstack-usage', snapshots / 'analysis_oracle.c', '-o', binary],
          output, 'compile-verifier', commands)
    layout_source = snapshots / 'capacity_layout.c'
    layout_source.write_text('#define main admitted_analysis_main\n#include "analysis_oracle.c"\n#undef main\n'
        'int main(void) { printf("{\\"maximumAcceptedSteps\\":%d,\\"maximumUnknowns\\":%d,'
        '\\"candidateRealBytes\\":%zu,\\"candidateImagBytes\\":%zu,\\"candidatePresenceBytes\\":%zu,'
        '\\"stepStorageBytes\\":%zu}\\n",MAX_STEPS,MAX_UNKNOWNS,sizeof candidate_real,'
        'sizeof candidate_imag,sizeof candidate_given,sizeof steps);return 0;}\n')
    layout_binary = output / 'capacity-layout'
    D.run([clang, *flags, layout_source, '-o', layout_binary], output, 'compile-layout', commands)
    layout = json.loads(D.run([layout_binary], output, 'capacity-layout', commands))
    assert layout['maximumAcceptedSteps'] == 1000 and layout['maximumUnknowns'] == 128
    stack_files = sorted(output.glob('*.su'));assert stack_files
    stack_frames = [int(line.split('\t')[1]) for path in stack_files for line in path.read_text().splitlines()]
    compile_receipt = {'compiler': {'path': str(clang), 'sha256': D.BASE.digest(clang)},
                       'commands': commands.copy(), 'layout': layout,
                       'maximumReportedFunctionStackBytes': max(stack_frames),
                       'stackUsage': [{'path': str(p), 'sha256': D.BASE.digest(p)} for p in stack_files],
                       'sourceDelta': {'beforeSHA256': old_source['sha256'], 'afterSHA256': sources[0]['sha256'],
                                       'onlyChanges': ['MAX_STEPS 256 to 1000', 'candidate bytes one MiB to eight MiB']}}
    D.BASE.save(output / 'compile-receipt.json', compile_receipt)
    result = copy.deepcopy(parent)
    result['validationOracle'] = {'path': str(binary), 'sha256': D.BASE.digest(binary),
                                  'compileReceipt': {'path': str(output / 'compile-receipt.json'),
                                                     'sha256': D.BASE.digest(output / 'compile-receipt.json')}}
    result['validationProfile'] = {'maximumAcceptedSteps': 1000, 'maximumUnknowns': 128,
                                   'maximumCandidateFileBytes': 8 * 1024 * 1024,
                                   'maximumCandidateJSONBytes': 8 * 1024 * 1024,
                                   'minimumOutputFreeBytes': 64 * 1024 * 1024}
    result['derivedFrom'] = {'manifest': parent_record, 'priorDerivation': parent.get('derivedFrom'),
                             'change': 'candidate verifier capacity only', 'allInputsAndReferencesUnchanged': True}
    result['sources'].extend(sources)
    for case in result['cases']:
        case['validationBaseCommand'] = [sys.executable, str(D.HERE / 'dynamic.py'), 'validate',
                                         '--manifest', str(output / 'manifest.json'), '--case-id', case['id']]
    staged = output / 'admission-manifest.json';D.BASE.save(staged, result)
    libraries = {row['id']: row for row in result['libraries']};checks = []
    selected = ['analytic-rc-ac', 'analytic-rc-noise', 'analytic-nonlinear-q',
                'analytic-retained-state', 'analytic-two-slot-state']
    selected += [next(c['id'] for c in result['cases'] if c['family'] == family and c['kind'] == 'transient')
                 for family in ('BULK', 'CMG', 'IMG', 'SOI')]
    for identifier in selected:
        case = next(c for c in result['cases'] if c['id'] == identifier)
        actual = json.loads(D.run(D.dynamic_command(binary, libraries, case['input']), output,
                                  'unchanged-' + identifier, commands))
        assert actual == case['reference'], identifier
        checks.append({'check': 'unchanged-old-domain-result', 'caseID': identifier, 'passed': True})
    case = next(c for c in result['cases'] if c['id'] == 'analytic-uic-rc')
    request = copy.deepcopy(case['input']);stop = request['analysis']['steps'][-1]['timeSeconds'];steps = [];previous = 0.
    for index in range(1000):
        time = stop * (index + 1) / 1000
        steps.append({'timeSeconds': time, 'timeStepSeconds': time - previous,
                      'method': 'backwardEuler' if index < 3 else 'trapezoidal'});previous = time
    request['analysis']['steps'] = steps
    large = json.loads(D.run(D.dynamic_command(binary, libraries, request), output, 'solve-1000', commands))
    assert large['status'] == 'passed' and len(large['acceptedSteps']) == 1000
    def replay(identifier, candidate, label, reject=False):
        path = output / (label + '.json');D.BASE.save(path, candidate)
        try:
            with redirect_stdout(io.StringIO()):
                D.validate(Namespace(manifest=staged, case_id=identifier, candidate=path, output=output / label))
        except RuntimeError:
            if not reject:raise
            receipt = D.read_analysis_json(output / label / 'receipt.json')
            assert receipt['commands'][-1]['exitCode'] == 3
        else:
            assert not reject, 'Corrupt candidate accepted'
        checks.append({'check': label, 'passed': True})
    replay(case['id'], large, 'candidate-1000')
    corrupt = copy.deepcopy(large);corrupt['points'][500]['unknowns'][0]['value'] += .01
    replay(case['id'], corrupt, 'reject-corrupt-1000', reject=True)
    over = copy.deepcopy(request);over['analysis']['steps'].append(
        {'timeSeconds': stop + steps[-1]['timeStepSeconds'], 'timeStepSeconds': steps[-1]['timeStepSeconds'], 'method': 'trapezoidal'})
    D.run(D.dynamic_command(binary, libraries, over), output, 'reject-1001', commands, expected=2)
    assert 'step limit' in (output / 'reject-1001.stderr').read_text()
    checks.append({'check': 'reject-1001', 'passed': True})
    native = D.read_analysis_json(args.native_candidate)
    assert 256 < len(native['acceptedSteps']) <= 1000
    replay('bsim-n-loaded-s4-transient', native, 'actual-native-bulk-candidate')
    for row in sources:
        assert D.BASE.digest(row['sourcePath']) == D.BASE.digest(row['snapshotPath']) == row['sha256']
    D.FAMILIES.checked_file(parent_record);D.FAMILIES.checked_file(result['validationOracle'])
    assert all(a['input'] == b['input'] and a['reference'] == b['reference'] for a, b in zip(result['cases'], parent['cases'], strict=True))
    shutil.copyfile(staged, output / 'manifest.json')
    proof = {'status': 'passed', 'manifestSHA256': D.BASE.digest(output / 'manifest.json'), 'checks': checks,
             'nativeAcceptedSteps': len(native['acceptedSteps']), 'nativeCandidateSHA256': D.BASE.digest(args.native_candidate),
             'layout': layout, 'commands': commands, 'toolSHA256': D.BASE.digest(__file__)}
    D.BASE.save(output / 'verification.json', proof)
    print(json.dumps({'manifest': str(output / 'manifest.json'), 'sha256': proof['manifestSHA256'],
                      'checks': len(checks), 'nativeAcceptedSteps': proof['nativeAcceptedSteps'], 'layout': layout}))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--native-candidate', type=Path, required=True)
    parser.add_argument('--clang', default='clang')
    parser.add_argument('--output', type=Path, required=True)
    capture(parser.parse_args())
