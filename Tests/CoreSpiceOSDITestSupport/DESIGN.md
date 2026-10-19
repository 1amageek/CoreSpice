# OSDI Test Manifest Support

## Purpose and Scope
Test-only module for the independent DC and dynamic analysis manifest value schemas. Parent: [CoreSpice](../../DESIGN.md#s3-osdi-dc-integration-contract). No children.

## Responsibilities and Boundaries
Decode immutable oracle inputs/results and typed OSDI assignments for adapter, native API and CLI behavioral tests. Does not implement equations, solving, production artifact admission or qualification policy.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Independent oracle](../../tools/OSDIDCVerification/DESIGN.md) | depends on | dc-manifest.v1 | Schema authority | Actual cases remain hash-bound |
| [Dynamic oracle](../../tools/OSDIDCVerification/DESIGN.md#s4-independent-dynamic-qualification) | depends on | analysis-manifest.v1 | Analysis-specific schema authority | DC evidence does not establish dynamic agreement |
| [CoreSpice](../../DESIGN.md) | parent | S3 evidence ownership | Test consumers only | Never a production dependency |

## Architecture
```text
immutable independent manifest -> test-only values -> separate adapter/API/CLI witnesses
```

## Contracts and Invariants

`OSDIFamilyProfileAdmission` consumes the tracked family authority at
`tools/OSDIModelQualification/profiles.json` and the manifest's explicit profile
binding. It requires the caller-selected profile (latest by default), all exact
family/version/source/library/request/case joins and recomputed matrix membership
before the adapter suite runs any model. Historical execution requires explicit
`CORESPICE_OSDI_DC_PROFILE=historical-soi47-v1`; it cannot satisfy latest admission.
The helper owns admission only. Independent oracle and actual adapter execution
remain separate behavioral witnesses. Negative completeness tests mutate required
family/version/source/library/case bindings and must fail before model loading.
Generated-image SHA-256 is pinned for every family in the tracked authority.
Coupled changes to the manifest library, its family binding and matrix therefore
fail admission even when those three untrusted records agree with each other.
Unknowns are optional only for expected failed references; successful cases must explicitly require every coordinate. Parameter kind and scope are decoded without coercion. Library paths and hashes are retained for exact model input admission, not interpreted as physics evidence.
Standalone Native/CLI DC fixtures use the same selected-profile admission before
executing any model. Representative prepared/executable case selection belongs
to that profile's authority and requires every selected case; a missing SOI case
cannot silently reduce coverage. Explicit library overrides for independently
bound dynamic/precision fixtures do not reinterpret their libraries as DC coverage.

`OSDIAnalysisManifest` reuses the existing DC library and circuit input types. Its
input additionally retains the nested circuit ID, while typed analysis values own
complex stimulus, waveform points, frequency/output selection, initialization,
UIC values and accepted time/h/method records. References preserve optional actual
operating points, scalar or complex unknowns, indexed raw noise PSD/contributions,
referral units, integrated noise and structured expected failures. Dynamic
unknowns do not require a DC-only residual-unit field. Fields absent for a failed
reference or inapplicable analysis remain optional; consumers must require the
fields used by a successful witness instead of manufacturing empty values.

`OSDIPrecisionManifest` decodes the explicit precision worker/model artifact paths,
SHA-256 values and byte counts, semantic/numeric profiles, selected bits and every
bounded worker option. Model entries project into the existing DC library value.
The manifest selects exact acquisition inputs; it does not contain reconstructed
model equations or replace the independent analysis input/reference manifest.
API and CLI tests share this one schema and require the declared environment input.

`OSDIPrecisionCLIFixture` materializes caller-owned temporary source and schema2
catalog files from that manifest. Family cases retain the independent source
inputs and use DC raw-node metadata only for connected-terminal order and storage
dimensions. Historical precision fixtures require the separate
`CORESPICE_OSDI_PRECISION_DC_MANIFEST`: its library ID, SHA-256, descriptor index
and name must match the exact precision image before captured node names are used.
The ordinary/latest `CORESPICE_OSDI_DC_MANIFEST` is not a fallback. Typed analysis
inputs retain authority over terminal count, connections and analysis conditions.
The independent capture retains the actual same-image metadata and command; a
different compiler output cannot borrow another image's topology witness.
A pilot explicitly selects the first requested stop; a full case
preserves its original stop. Compound/context sources match the API witnesses.
The helper derives precision adapter storage through its owning capacity API and
adds worker arena/mapping admission to the existing Native/live envelopes. Five
explicit execution bounds are exported for test mutation; these are admission
ceilings, not measured RSS or qualification claims. The caller owns process
execution, serialization assertions, cancellation, cleanup and test exclusion.

## Verification and Change Impact
Existing adapter cases and new native/CLI tests compile and execute through this single schema. A schema change requires reviewing these consumers; no solver or output predicate is shared with the independent C oracle.
The S4 consumers decode the exact frozen fifty-case capture, including all four
expected negative-PSD failures and forty-six successful references, through this
same test-only DTO. Root owns the shared-target build and consuming behavioral
tests; the DTO owner does not run a competing Swift build.

The successful independent references do not authorize every consumer to claim
ordinary binary64 transient success. CLI execution witnesses have these explicit
owners; the ordinary suite checks the exact twelve-case transfer to the full
precision plan instead of silently skipping those cases.

| Witness | Scope |
|---|---|
| [Ordinary dynamic CLI](../CoreSpiceOSDICLITests/OSDIAnalysisCLIExecutionTests.swift) | Four-family AC/noise, all four negative PSD cases, analytic transient controls, selected CSV, strict reload, cancellation, bounded refusal and retained ordinary rerun |
| [Full precision CLI](../CoreSpiceOSDICLITests/OSDIPrecisionFullScheduleCLITests.swift) | All twelve original real-model transient schedules through actual CLI and complete paired persistence |
| [Full precision Native](../CoreSpiceOSDINativeTests/OSDIPrecisionFullScheduleTests.swift) | The same original transient cases through paired API, accepted history and original equation policy |

Changing the frozen real-model transient case set requires updating the explicit
CLI ownership assertion and the separately filterable precision witnesses. No
test migration changes source schedules, numerical tolerances or caller budgets.
The ordinary CLI fixture obtains analytic connected-terminal order by preparing
the exact hash-bound model with the case's assignments and temperature, then
reading its actual topology. Analytic models do not borrow a real-device DC
catalog entry or infer terminal order from dictionary iteration. Temporary model
preparation and its staged library close before the CLI fixture is executed.

The same actual-model topology path applies to real-model ordinary CLI fixtures;
the separately selected latest DC profile is not their metadata authority.
Latest SOI AC/noise witnesses require the explicit
`CORESPICE_OSDI_SOI101_ANALYSIS_MANIFEST` and its exact SOI101 library image.
They reuse the complete Native/CLI reference comparison and persistence checks,
while retaining the historical fifty-case schedule as a separate obligation.
The retained six-terminal SOI101 inputs and references do not qualify another
image, release, selector or frequency range.
