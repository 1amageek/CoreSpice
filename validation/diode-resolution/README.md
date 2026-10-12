# D3 Diode Resolution Verification

D3 owns source admission and resolution, not diode numerical physics. The authority
is [DiodeResolution](../../Sources/CoreSpiceLowering/DiodeResolution/DESIGN.md).

## Execution boundaries

```text
raw SPICE / canonical ParsedIR
 -> compiled occurrence index and ordered programs
 -> existing D2 frozen evaluator
 -> shared checked model + independent AREA/PJ/M/thermal instance input
 -> Instance.diode.resolved
 -> explicit compiler / direct binding / native preparation refusal
```

An explicit `diodeProfile: .coreDiodeV1` is required by `session.lower`,
`SPICEIO.parseAndLower`/`lower`, or `SPICESimulationPreparationRequest` for an
encountered diode. The MOS profile does not select it. Direct ParsedIR uses
`ParsedDiodeInput.model` and `.component` with ordered assignments; unavailable
source origins remain unavailable. Nonempty dictionaries without occurrence
metadata refuse. Model grading `m` and instance multiplicity `m` never merge.

## Counterexample owners

| Invariant | Behavioral proof |
|---|---|
| Raw and direct input roles, normalization once | directRolesAndNormalization, rawRolesAndTemperature, defaultsAreNotRescaled |
| Unknown, wrong-role, duplicate, non-scalar and selector refusal | unknownAndWrongRoleRefuseEvenZero, duplicateAssignmentsAndSelectorsRefuse, nonScalarAndMissingOccurrenceEvidenceRefuse |
| No lost source tokens or declarations | sourceTokensCannotDisappear, duplicateModelsKeepBothOrigins, includeReappearanceRetainsBothDeclarationOccurrences |
| Exact owning scope and X invocation isolation | nearestScopeDoesNotFallbackAndSiblingsAreIsolated, perInvocationModelEvaluationAndBindingMemo |
| Model sharing, binding memo, deterministic PRNG | modelMemoAndRandomDrawsAreOwnedOnce, perInvocationModelEvaluationAndBindingMemo |
| Explicit vs inherited X multiplicity | explicitCallerMultiplicityAndImplicitRefusal |
| Frozen environment and numeric boundaries | environmentMismatchAndNormalizationBounds, suppliedZeroAndNonfiniteAreNotDefaults |
| Bounded failure, cancellation, no partial circuit | selectedDeclarationOnlyAndResourceLimits, diagnosticTextIsBoundedWithoutChangingRefusal, refusalPoisonsSessionAndDoesNotPublishPartialCircuit, cancellationPublishesNoPartialCircuitAndPoisonsOwner |
| Source context survives failure | scalarFailuresAreStructured, instanceFailureRetainsExactAssignmentSource, publicErrorsRetainSourceAndExplicitProfile |
| No numerical bypass; clones preserve stage | publicParseLowerRefusesNumericalBypass, resolvedDiodeRefusesNativeBeforeAllocation |
| Retained diagnostic owns accounting until release | diodeDiagnosticRetainsAndReleasesFrontendAccounting |

Tests reside in `CoreSpiceDiodeResolutionTests`, `CoreSpiceDiodeIntegrationTests`
and the named extension in `CoreSpiceNativeExecutionTests`. The independent
resolution tests import neither Devices nor IO nor an external simulator/GPU.
The public integration tests use the actual IO, compiler, registry and native
preparer. Existing MOS, resistor, parser, IR and IO suites own regression evidence.

## Ownership and target review

| State | Native | WASM / Embedded | Lifetime / mutation |
|---|---|---|---|
| Checked model and instance values | Immutable Sendable | Same declarations | No mutable shared storage |
| Resolved model backing | Immutable Sendable class | Same declarations | Retained by result; sameStorage inspects sharing only |
| Evaluation state / RNG / binding memo | Existing noncopyable evaluator | Same evaluator source and isolation | Exclusively owned, poison on failure |
| Diode model memo / frontend index | Noncopyable frontend / immutable compiled owner | Frontend platform scope unchanged | One exclusive frontend session; no shared mutation |
| Source diagnostic reservation | Shared immutable release owner | Host IO scope unchanged | Copies retain one exactly-once release callback |

There is no target-specific synchronization branch in the new production sources.
Pure contract/evaluator compile-link-runtime evidence is separate from Native-only
frontend/numerical refusal evidence. Numerical execution or physical accuracy is
not inferred from any resolution success.

## Review findings and closure

One overall review identified model-owner reservation after allocation, instance
source-context loss, projection comparisons not individually charged, premature
release of diagnostic accounting, and obsolete source execution coverage. Fixes
reserve before allocation, retain exact assignment coordinates and the frontend
reservation, charge comparisons, preserve the staged value across clones, and
refuse unprepared numerical paths before allocation. Finding-specific behavioral
checks above close these issues; D4/D5 remain separate implementation units.

## Reproduction

`fixture.py --output <run-directory>` retains exact production declarations,
URL dependencies and Package.resolved while selecting affected tests. Source and
test directories are symlinks to production, not patched copies. Stage cold
CoreSpiceIO dependencies before bounded tests. Use Swift 6.4.0 release and the
matching WASM SDKs. Tests use the repository timeout helper with an outer ceiling
of 120 seconds. The D1 contract and D2 evaluator verification runners independently
check pure targets on Native, ordinary WASM and Embedded WASM.

The task evidence directory contains command logs, exact source hashes and commit
identity; test counts and success are recorded only after actual execution.

`verify-contracts.py --output <run-directory>` constructs the new immutable D3
model/instance values, checks shared backing, both m roles, normalized geometry
and mixed-environment refusal on Native, ordinary WASM and Embedded WASM. Runtime
success requires the explicit `D3-CONTRACTS-PASS` marker after all checks. WASI
receives an argv[0]; process exit alone is not accepted as runtime proof.
