#!/usr/bin/env python3
"""Admission regressions only: metadata fixtures never claim numerical qualification."""
import copy
import unittest

import family_profile as admission


def metadata_fixture(identifier):
    specifications, requests, baseline = admission.load(identifier)
    libraries, cases, bindings, matrix = [], [], {}, {}
    for request in baseline:
        cases.append({'id': request['id'], 'input': request,
                      'reference': {'status': request['expectedOutcome']}})
    for family, specification in specifications.items():
        library = {'id': specification['libraryID'], 'path': '/admission-fixture/never-executed',
                   'sha256': specification['artifactSHA256'],
                   'descriptorIndex': specification['descriptorIndex'], 'descriptorName': specification['descriptorName']}
        libraries.append(library)
        bindings[family] = admission.binding(specification, library)
        matrix[family] = {'version': specification['version'], 'status': 'captured',
            'caseIDs': specification['requiredCaseIDs'], 'libraryID': library['id'], 'librarySHA256': library['sha256']}
        if family != 'BULK':
            for request in requests[family].values():
                cases.append({'id': request['id'], 'family': family, 'input': request,
                              'reference': {'status': request['expectedOutcome']}})
    return {'schema': 'corespice.osdi.dc-manifest.v1', 'status': 'passed', 'libraries': libraries,
        'cases': cases, 'familyBindings': bindings, 'familyMatrix': matrix, 'qualificationComplete': True,
        'qualificationProfile': {'id': identifier, 'sha256': admission.digest(admission.AUTHORITY)}}


class FamilyProfileTests(unittest.TestCase):
    def test_explicit_finite_profiles_admit_their_own_complete_metadata(self):
        for identifier in ['historical-soi47-v1', 'latest-soi101-v1']:
            with self.subTest(profile=identifier):
                admission.validate(metadata_fixture(identifier), identifier)

    def test_missing_or_misbound_family_version_source_library_case_and_policy_are_rejected(self):
        def omit_family(value):
            del value['familyBindings']['SOI']
            value['cases'] = [case for case in value['cases'] if case.get('family') != 'SOI']
        def omit_case(value):
            value['cases'] = [case for case in value['cases'] if case['id'] != 'soi101-p-pd-reverse']
        def wrong_input_library(value):
            case = next(case for case in value['cases'] if case.get('family') == 'SOI')
            case['input']['devices'][0]['library'] = 'cmg'
        def wrong_policy(value):
            case = next(case for case in value['cases'] if case.get('family') == 'SOI')
            case['input']['policy']['equationAbsoluteTolerances']['A'] = 1.0
        mutations = {
            'missing-soi-despite-33-other-cases': omit_family,
            'missing-required-polarity-direction': omit_case,
            'wrong-case-library': wrong_input_library,
            'relaxed-equation-policy': wrong_policy,
            'wrong-version': lambda value: value['familyBindings']['SOI'].update(version='4.7.0'),
            'wrong-source': lambda value: value['familyBindings']['SOI']['sourceSHA256'].update({'bsimsoi.va': '0' * 64}),
            'wrong-compiler': lambda value: value['familyBindings']['SOI'].update(compilerSHA256='0' * 64),
            'wrong-library-digest': lambda value: next(lib for lib in value['libraries'] if lib['id'] == 'soi101').update(sha256='b' * 64),
            'wrong-descriptor': lambda value: next(lib for lib in value['libraries'] if lib['id'] == 'soi101').update(descriptorName='other'),
            'missing-library': lambda value: value.update(libraries=[lib for lib in value['libraries'] if lib['id'] != 'soi101']),
            'wrong-case-family': lambda value: next(case for case in value['cases'] if case.get('family') == 'SOI').update(family='IMG'),
            'stale-matrix': lambda value: value['familyMatrix']['SOI'].update(version='4.7.0'),
            'wrong-profile-digest': lambda value: value['qualificationProfile'].update(sha256='0' * 64),
            'duplicate-case': lambda value: value['cases'].append(copy.deepcopy(value['cases'][0])),
            'unknown-case': lambda value: value['cases'].append({'id': 'unapproved'}),
        }
        for label, mutation in mutations.items():
            with self.subTest(counterexample=label):
                value = copy.deepcopy(metadata_fixture('latest-soi101-v1'))
                mutation(value)
                with self.assertRaises(ValueError):
                    admission.validate(value)

    def test_appended_single_latest_point_cannot_relabel_historical_profile(self):
        value = metadata_fixture('historical-soi47-v1')
        latest = metadata_fixture('latest-soi101-v1')
        value['libraries'].append(latest['familyBindings']['SOI']['library'])
        value['cases'].append(next(case for case in latest['cases'] if case['id'] == 'soi101-n-dd-loaded'))
        with self.assertRaises(ValueError):
            admission.validate(value)
        value['qualificationProfile'] = latest['qualificationProfile']
        with self.assertRaises(ValueError):
            admission.validate(value)

    def test_coupled_library_and_binding_digest_changes_cannot_select_another_image(self):
        for identifier in ['historical-soi47-v1', 'latest-soi101-v1']:
            specifications, _, _ = admission.load(identifier)
            for family, specification in specifications.items():
                with self.subTest(profile=identifier, family=family):
                    value = metadata_fixture(identifier)
                    library = next(item for item in value['libraries'] if item['id'] == specification['libraryID'])
                    library['sha256'] = '0' * 64
                    value['familyBindings'][family]['library']['sha256'] = '0' * 64
                    value['familyMatrix'][family]['librarySHA256'] = '0' * 64
                    with self.assertRaises(ValueError):
                        admission.validate(value, identifier)


if __name__ == '__main__':
    unittest.main()
