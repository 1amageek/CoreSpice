#!/usr/bin/env python3
"""Bind existing qualified precision images/worker/options for API and CLI tests."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

MAX_BYTES = 256*1024*1024
OPTION_NAMES = {'arenaBytes', 'maximumProgramBytes', 'maximumMappingBytes',
                'minimumPrecisionBits', 'maximumPrecisionBits', 'maximumWorkUnits',
                'startupTimeoutNanoseconds', 'evaluationTimeoutNanoseconds',
                'cleanupTimeoutNanoseconds', 'pollNanoseconds'}


def identity(path, expected=None):
    path = Path(path).resolve(strict=True)
    size = path.stat().st_size
    if size > MAX_BYTES:
        raise ValueError('input_size')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while data := stream.read(65536):
            digest.update(data)
    result = {'path': str(path), 'sha256': digest.hexdigest(), 'byteCount': size}
    if expected is not None and result['sha256'] != expected:
        raise ValueError('identity_mismatch:' + str(path))
    return result


def read(path):
    identity(path)
    if Path(path).stat().st_size > 16*1024*1024:
        raise ValueError('receipt_size')
    return json.loads(Path(path).read_text())


def generate(worker_receipt, public_directory, compiler_directory, independent_proof, output, context_receipt=None, derived_from=None):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    snapshots = output/'inputs'
    snapshots.mkdir()
    provenance = []
    def receipt(path):
        record = identity(path)
        target = snapshots/(str(len(provenance))+'-'+Path(path).name)
        shutil.copyfile(path, target)
        snapshot = identity(target, record['sha256'])
        provenance.append({'original': record, 'snapshot': snapshot})
        return read(target)
    own = snapshots/'precision_manifest.py'
    shutil.copyfile(__file__, own)
    worker = receipt(worker_receipt)
    request = receipt(Path(public_directory)/'img-request.json')
    receipt(Path(public_directory)/'receipt.json')
    profile = identity(worker['numericProfile']['path'], worker['numericProfile']['sha256'])
    receipt(worker['numericProfile']['path'])
    executable = identity(worker['worker']['path'], worker['worker']['sha256'])
    if request['numericProfileSHA256'] != profile['sha256'] or set(request['options']) != OPTION_NAMES:
        raise ValueError('numeric_option_authority')
    semantic = request['semanticProfileSHA256']
    if len(semantic) != 64 or not all(c in '0123456789abcdef' for c in semantic):
        raise ValueError('semantic_identity')
    compiler_directory = Path(compiler_directory)
    compiled = receipt(compiler_directory/'models-5/receipt.json')
    compilation = {entry['family']: entry for entry in compiled}
    for identifier in ('compound', 'context'):
        name = 'compound' if identifier == 'compound' else 'precision-context'
        compilation[identifier] = receipt(compiler_directory/'fixtures'/(name+'-final-receipt.json'))
    expected_compilers = {}
    bridge = None
    parent_identity = None
    if bool(context_receipt) != bool(derived_from):
        raise ValueError('derived_authority_pair_required')
    if context_receipt:
        bridge = receipt(context_receipt)
        parent_identity = identity(derived_from)
        parent = receipt(derived_from)
        if parent['semanticProfileSHA256'] != semantic or bridge['semanticProfileSHA256'] != semantic:
            raise ValueError('derived_semantic_mismatch')
        context_records = [x for x in bridge['artifacts'] if x['name'] == 'precision-context']
        if len(context_records) != 1:
            raise ValueError('context_receipt_missing')
        compilation['context'] = context_records[0]
        expected_compilers['context'] = bridge['compiler']['sha256']
    models = []
    for identifier in ('bsim', 'cmg', 'img', 'soi', 'compound', 'context'):
        family = 'bulk' if identifier == 'bsim' else identifier
        compile_record = compilation[family]
        if compile_record['exitCode'] != 0 or ('inspectionExitCode' in compile_record and compile_record['inspectionExitCode'] != 0):
            raise ValueError('compile_failure')
        argv = compile_record['command']
        if argv[1:4] != ['--full-residuals', '--precision-v1', semantic]:
            raise ValueError('compile_profile_mismatch')
        image = identity(argv[argv.index('-o')+1], compile_record['imageSHA256'])
        source = identity(argv[-1], compile_record.get('sourceSHA256'))
        module_names = set(re.findall(r'^module\s+(\w+)\s*\(', Path(source['path']).read_text(), re.M))
        if len(module_names) != 1:
            raise ValueError('module_name_ambiguity')
        image_path = Path(image['path'])
        inspection = receipt(image_path.parent/(image_path.stem+'-program')/'receipt.json')
        if inspection['librarySHA256'] != image['sha256'] or len(inspection['programs']) != 1:
            raise ValueError('program_image_binding')
        program = inspection['programs'][0]
        if program['descriptorIndex'] != 0 or program['semanticProfileSHA256'] != semantic:
            raise ValueError('program_profile_binding')
        program_identity = identity(program['programPath'], program['sha256'])
        compiler = identity(argv[0], expected_compilers.get(family))
        if bridge and family in ('bulk', 'cmg', 'img', 'soi'):
            retained = bridge['modelsRetainedWithoutAnalysisInputs'][family]
            if retained['analysisFactCount'] != 0 or retained['programSHA256'] != program_identity['sha256']:
                raise ValueError('retained_model_premise_changed')
        models.append({'id': identifier, **image, 'descriptorIndex': 0,
                       'descriptorName': next(iter(module_names)),
                       'program': program_identity, 'source': source, 'compiler': compiler})
    proof = receipt(independent_proof)
    if not proof['passed'] or sum(x['channels'] for x in proof['families']) != 116:
        raise ValueError('independent_proof_missing')
    result = {'schema': 'corespice.osdi.precision-manifest.v1', 'worker': executable,
              'semanticProfileSHA256': semantic, 'numericProfileSHA256': profile['sha256'],
              'precisionBits': request['precisionBits'], 'options': request['options'],
              'models': models, 'provenance': provenance, 'generator': identity(own),
              'independentPointProof': identity(independent_proof),
              'scope': 'Qualified final point profile and exact consumer inputs; complete circuit trajectories are separately verified.'}
    if parent_identity is not None:
        result['derivedFrom'] = parent_identity
        result['contextReplacementReceipt'] = identity(context_receipt)
        old = {x['id']: x for x in parent['models']}
        for model in models:
            if model['id'] != 'context' and model != old[model['id']]:
                raise ValueError('unrequested_model_change')
    path = output/'manifest.json'
    with path.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    return identity(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker-receipt', required=True)
    parser.add_argument('--public-directory', required=True)
    parser.add_argument('--compiler-directory', required=True)
    parser.add_argument('--independent-proof', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--context-receipt')
    parser.add_argument('--derived-from')
    args = parser.parse_args()
    print(json.dumps(generate(**vars(args)), indent=2))


if __name__ == '__main__':
    main()
