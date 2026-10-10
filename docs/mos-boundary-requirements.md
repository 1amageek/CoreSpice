# MOS Boundary Requirement Traceability

This is the evidence index for the user-approved R01–R35 requirements. Concise
intent labels identify those requirements; the linked DESIGN documents remain the
contract authorities. This index does not replace their contracts or declare S5
complete. Workspace [PROGRESS](../../PROGRESS.md), item B8.6.5.18, owns task status.

```text
source identity / explicit profile
    -> selection + immutable resolved values
    -> exact-release numerical preparation + receipt
    -> consuming bind + actual analysis
    -> separately scoped numerical comparison / physical qualification
```

Selection success proves input interpretation. Preparation success proves admission
of an exact release and conditions. Execution evidence requires an actual completed
analysis. None of those alone qualifies a process, corner, foundry model, GPU, or
numerical WASM/Embedded backend. Independently inspectable BSIM4.5 remains a typed
native preparation refusal; a supported release cannot substitute for it.

## Verified Evidence and Remaining Work

Evidence links point to retained local verification artifacts outside the package.
Their source hashes, selected methods, runtime events and stated platform scopes
bound the claims below. Earlier failed iterations are not green evidence. S1–S3
closure records explain their constituent runs, including repaired failures; S4
links are focused results and finding rechecks. E5R reconciles the committed S4
production and adopted callers; workspace PROGRESS records the final documentation/test
commit and task completion.

| Key | Verified artifact | Scope |
|---|---|---|
| E1 | [S1 closure][e1] | Commit `08d1f47`: contracts/schema and ordered intake; 299 Native methods, including 17 pure methods; portable evidence is limited to its recorded source/toolchain. |
| E2 | [S2 closure][e2] | Commit `48e5992`: 55 independent resolution methods, aggregate findings closed; [portable run][e2p] and production dependency graph. |
| E3 | [S3 closure][e3] | Commit `f816ee6`: 111 Native methods across preparation, stage, kernel and Native composition; [pure preparation portable run][e3p]. |
| E4F | [S4 adapter green][e4f], [frontend recheck][e4fr], [IO/CLI recheck][e4ir] | Actual Lowering/IC tests and closure of static signed-power, dynamic-conditional and authoritative-control findings. |
| E4I | [S4 IO exact-encoding green][e4i] | 120 IO + 8 IC actual methods; shared frontend, authoritative IC and exact-capacity semantic encoding with cleanup. |
| E4N | [S4 Native exact-encoding green][e4nl], [budget green][e4n], [Fourier green][e4q] | Latest Native run: 23 actual methods plus one opt-in skip. Composed execution, numerical budgets and result-owner lifetime; Fourier refusal/cleanup is separately scoped. |
| E4B | [S4 BSIM shared-budget green][e4b] | 37 actual Native integration/noise methods; current/charge-derived Jacobian/DC/AC/transient assertions and prime-node/history IC paths. Numerical implementation is unchanged from this run; identity-encoding composition is separately verified by E4I/E4N/E4C. |
| E4A | [S4 Analysis shared-budget green][e4a], [Devices green][e4d] | Latest Analysis run: 243 actual methods; earlier Devices run: 181 actual methods. These numerical scopes do not qualify a process. |
| E4H | [S4 PDK preview with override][e4h] | Focused PDK caller preview. Not final normal-resolution Host/Studio/PDK adoption proof. |
| E4C | [S4 CLI exact-encoding green][e4c] | 99 actual CLI methods, including retained source-catalog execution after source files change; local API composition, separately complemented by E5C process evidence. |
| E5P | [Final exclusive-program pure Native green][e5pn], [final exclusive-program portable green][e5pp] | 69 actual Native methods after exclusive prepared-program ownership, including the 40-case boundary matrix; Swift 6.4.0 exact production pure bytes compile/link/synchronous runtime on Native, WASM and Embedded. No numerical portable backend claim. |
| E5S | [Original Sky130 integrity/command][e5si], [observed selection][e5ss] | Complete 8323-file original PDK inventory unchanged; nfet TT exact source interpretation and 4.5 native preparation refusal. Details below. |
| E5M | [Release performance verification][e5mv], [performance summary][e5ms] | Two-sample cold/reuse pilot per Level 1/BSIM3/BSIM4, calibrated allocation API counters, explicit unavailable copy/global-kernel metrics. Details below. |
| E5C | [Actual CLI process verification][e5c] | Native strict-profile seed-42 supported op succeeds; exact 4.5 fails at preparation with mos.preparation category. Retained invocation identity and actual input artifact; the shared-cache executable may subsequently be overwritten. |
| E5H | [Normal PDKKit][e5pdk], [normal Xcircuite Host][e5host], [normal circuit-studio][e5studio] | 10 / 37 / 20 actual methods with normal dependency resolution; these replace preview-only adoption assurance. |
| E5R | [Cumulative reconciliation][e5r], [exact adopted revisions][e5ledger] | PASS: Core S4 `60543b6fca295827d568a5d73a3e8134e6419997`, 747 unchanged production files, and all 19 caller commits (20 repositories including Core). Reconciles E5P/E5S/E5M/E5C/E5H within their recorded scopes, before the S5 documentation/test-only commit. |

The following table records scoped evidence closure; workspace PROGRESS owns commit status.
Numerical and qualification limitations remain attached to their local evidence.

| Gap | Evidence status and exact remaining work |
|---|---|
| G1 | Verified by E5S: original nfet TT model/mismatch includes under pinnedNgspiceNormalV1, seed 42, scale 1e-6; actual `.98` declaration/source/ranges and exact BSIM4.5 native refusal. This closes original-input interpretation/refusal evidence, not Sky130 numerical physics or every device/corner. |
| G2 | Local supported-release Native numerical matrix is verified by E3/E4B/E4A with separate tolerances indexed below. Reuse that evidence for unchanged numerical bytes; public composition is reconciled by E5R (G5). Captured comparator fixtures are existing evidence, not a new live external invocation. Any new comparison is conditional and must match inputs/releases/conditions and separate discrepancy layers. Process accuracy remains unqualified. |
| G3 | Verified by E5P for the recorded pure source hashes and Swift 6.4.0 release with matching WASM/Embedded SDKs: compile, link and synchronous runtime. Cumulative source/caller reconciliation is verified by E5R (G5); this does not establish portable numerical physics, GPU or unexercised concurrency. |
| G4 | Verified by E5M within the pilot scope: release-mode cold/reuse timing, resource-admission peaks, evaluator/RNG work and receipt coldSetupCount, calibrated allocation API entries/requested bytes, heap live metrics/RSS. Physical copy calls and independent global kernel-call events are null/unavailable; no statistical speedup, zero-copy, or global-call-count claim. |
| G5 | Verified by E5R/E5H: committed Core S4 `60543b6` plus all 19 exact caller revisions, normal PDKKit/Host/Studio execution, and cumulative method/event/source-hash reconciliation. Existing review and runtime evidence retains its scope. Workspace PROGRESS records the final S5 documentation/test-only commit and task completion; this index is not commit evidence. |

## Numerical Tolerance and Evidence Index

These values index the assertions in the linked tests; they do not introduce new
acceptance limits. `S(a, r)` denotes `abs(actual - expected) <= a + r *
max(abs(actual), abs(expected))`. Where a test uses only the expected magnitude,
the table states that separately. Solver convergence tolerances and bin-selection
endpoint tolerances are distinct from these numerical comparison tolerances.

The BSIM integration fixtures use explicit level 49/version 3.3.0 or level
54/version 4.8.3 through their [shared Native fixture][nfixture3]/[BSIM4 fixture][nfixture4].
Those fixtures resolve once, prepare with explicit ambient/nominal conditions and
requested capabilities, and bind the same receipt. They are numerical evidence
for those releases. BSIM4 4.5 is selection/inspection-only evidence plus an exact
native preparation refusal; none of the rows below supplies 4.5 numerical physics.

| Quantity / boundary | Source-backed test and input scope | Assertion tolerance / evidence |
|---|---|---|
| Level 1 device small-signal derivatives | [MOSFETPhysicsTests][tphysics] `nmosSmallSignalParameters`, prepared `nmos_l1`; saturation formulas with CLM/body effect | Relative error `< 0.15` for gm/gds and `< 0.2` for gmbs; E4A Devices. These are analytical sanity limits, not foundry-model accuracy. |
| Level 1 actual DC current | [DevicePhysicsTests][tanalysisphysics] `mosfetOutputCharacteristics`, Level 1 NMOS VGS/VDS sweep | Saturation current relative error `< 0.15` against `0.5 * beta * (VGS - VTO)^2`; E4A Analysis. |
| BSIM3 kernel current / operating-point derivatives | [BSIM3KernelTests][tkernel3] `independentNgspiceFixturesAgree`, 18 NMOS/PMOS bias/temperature/capmod cases, exact 3.3.0 | `S(1e-20, 2e-10)` for Id/gm/gds/gmbs; E3. |
| BSIM3 charge and charge derivatives | [BSIM3KernelTests][tkernel3] same captured fixture states qg/qd/qb; `terminalJacobiansMatchFiniteDifferences`, both polarities/capmod 0–3 and multiple bias regions | Charge states `S(1e-26, 2e-10)`; dQ/dV `S(1e-20, 3e-4)` with ±1e-6 V perturbation. Charge conservation is checked separately by `coldOfficialPhysics`; E3. Normalized charge-state queries are distinguished from physical-polarity terminal charges in the test. |
| BSIM4 kernel current / intrinsic charge | [BSIM4KernelTests][tkernel4] `independentOriginalOperatingPointFixtures`, 22 exact 4.8.3 cases, fixture temperature/model/geometry/bias | Seven operating-point entries: `1e-13 + 2e-7 * abs(expected)`; four intrinsic charges: `1e-23 + 2e-7 * abs(expected)`; E3. Entries retain their own units; this is not one combined accuracy claim. |
| Bound DC/transient Jacobian | [BSIM3 integration][tbsim3] / [BSIM4 integration][tbsim4] `boundCurrentAndTransientJacobiansMatchFiniteDifferences`, both polarities, QS/NQS, nil/BE/trapezoidal stamps | ±1e-6 V centered differences; BSIM3 `S(1e-12, 4e-4)`; BSIM4 `S(1e-12 + rounding, 4e-4)`, with source-defined rounding `(variableCount + 2) * ulpOfOne * weightedResidual / 1e-6`. Direct CSR and callback stamps must also be exactly equal; E4B. |
| Actual BSIM DC branch currents | [BSIM3 integration][tbsim3] / [BSIM4 integration][tbsim4] `productionDCMatchesIndependentFixtures`, 18 / 22 cases | BSIM3 `S(5e-12, 5e-8)`; BSIM4 `S(2e-12, 2e-7)` for terminal source currents; E4B. |
| Actual BSIM AC complex terminal currents | [BSIM3 integration][tbsim3] / [BSIM4 integration][tbsim4] `actualACAndTransientMatchIndependentTerminalOracle`, 4 / 6 source cases | Real and imaginary parts checked separately: BSIM3 `S(2e-12, 1e-7)` at 1e8 Hz; BSIM4 `S(2e-12, 2e-7)` over 1e3–1e11 Hz. E4B. |
| Actual BSIM transient terminal currents | Same integration methods and fixture sources; 2 ns run with max/initial step 2 ps, linear interpolation at captured sample times | Both terminal currents `S(5e-9, 3e-3)`; BSIM4 explicitly uses BE and records `dt/period <= 2e-4`. Integration/interpolation error is distinct from DC/kernel error. E4B. |
| Analysis AC/transient algorithm references | [ACIntegrationTests][tanalysisac] `rcLowpassFilter`; [TransientAccuracyTests][tanalysistran] `rcTimeConstantPrecision` | RC AC: 0.5 dB near passband/corner, 1.5 dB at 10×/100× corner; RC transient: absolute voltage error `< 0.02` at 0.5/1/2 tau and `< 0.015` at 3 tau. E4A. These passive analytical references prove algorithm behavior, not MOS-release physics. |

Existing external-derived expected values are retained in the [BSIM3 kernel
oracle][oracle3], [BSIM4 kernel reference][oracle4], [BSIM3 analysis oracle][aoracle3]
and [BSIM4 analysis oracle][aoracle4]. Their provenance records exact releases,
fixture inputs/conditions and executable or source/archive digests. The analysis
oracles also disclose reference-only derivative/geometry or charge-multiplicity
corrections; they are comparisons against those stated references, not claims of
unmodified external-tool equivalence. Tests consume the captured values locally;
E3/E4B do not assert a fresh ngspice invocation. A new external comparison is
optional; when performed, selection/normalization, exact-release preparation and
numerical discrepancies must be reported separately. None establishes original
Sky130 process/corner accuracy or physical qualification.


## Original Input and Performance Evidence

E5S records Volare Sky130A version `c6d73a35f524070e85faff4a6a9eef49553ebc2b`:
8323 files / 1,106,813,243 content bytes have equal complete before/after inventories.
The actual caller includes unchanged nfet TT and mismatch sources, uses raw
W=0.65/L=0.15/NF=1 and scale 1e-6, and selects
`sky130_fd_pr__nfet_01v8__model.98` at TT source line 26597. Held bounds are
W=[640,650] nm and L=[150,180] nm; normalized W/L are 650/150 nm. The same
retained declaration has level 54/version 4.5; numerical preparation returns
`mosPreparation.unsupportedRelease.bsim4_4_5`. The [actual test][tsky] checks
source occurrence coordinates, scope, profile and identity before recording the
observation. Neither this refusal nor the independent strict-profile CLI process
E5C substitutes an executable release or qualifies original 4.5 physics.

E5M uses Swift 6.4.0 release / Native CPU SparseLUSolver. Cold samples start in a
new process and measure original-string parse/compile/resolve/prepare/five-point
DC; source-file reads and process startup are excluded from the phase total.
Reuse compiles once and creates a fresh evaluation session and Native owner for
each sample. Instrumented allocation timing is excluded from numeric timings.

| Release | Cold median (ms) | Reuse median (ms) | Samples per mode |
|---|---:|---:|---:|
| Level 1 | 6.802 | 2.751 | 2 |
| BSIM3 3.3.0 | 7.454 | 6.182 | 2 |
| BSIM4 4.8.3 | 9.580 | 6.344 | 2 |

The summary links exact source/fixture hashes and calibration. Counts cover
interposed malloc/calloc/realloc/free API entries and requested bytes, including
failed requests/nested entries; direct zone APIs and physical copies are
unmeasured. Resource reservation peaks are admission capacities, separate from
heap bytes/blocks and peak RSS. Published coldSetupCount and downstream work
deltas support the stated owner/evaluation boundary; independent global kernel
hooks remain unavailable. These are representative pilot measurements, not a
statistical speedup or zero-copy proof. E5R closes cumulative adoption/source
reconciliation (G5); workspace PROGRESS records the final documentation/test-only commit.

## Requirement Mapping

Behavioral test cells name actual test owners and representative counterexamples;
the evidence artifacts, rather than a test declaration alone, establish execution.
Implementation links identify the responsible production boundary, not alternate
model-selection or evaluation authorities.

| ID | Intent | Exact owner and implementation | Behavioral test / counterexample | Verified evidence | Scoped closure / limitations |
|---|---|---|---|---|---|
| R01 | Explicit input specification | [Contracts Values][values]: [MOSInputProfile][profile]; [Frontend][frontend]: [beginEvaluation][lowering] | [FrontendSessionTests][tfront]: `compileOnceSupportsDistinctRootActualsAndSeeds`; [MOSEvaluationTests][teval]: complete-request profile/condition mismatch | E1, E2, E4F, E5S, E5P, E5R | G1 verified by E5S (nfet TT only); G3 pure snapshot verified by E5P; G5 verified by E5R. |
| R02 | Exact physical release, no substitution | [Schema][schema]: [MOSModelRelease][release]; [Preparation][prep]: [NativeMOSDevicePreparer][preparer] | [MOSNormalizationTests][tnorm]: explicit/default origins and exact non-executable 4.5; [MOSPreparationTests][tprep]: `inspected45AndLowStorageAndCancellationNeverPublishOwner` | E1–E3, E5S, E5R | G1 verified by E5S (nfet TT only); G2 only admitted exact releases. |
| R03 | Process/corner/card/coefficient/range/source identity | [Declarations][decl]: [snapshot builder][builder]; [Frontend][frontend]: [modelOrigin][compiled]; [PDK inspection][pdk]: actual source projection | [MOSSnapshotTests][tsnapshot]: ordered source occurrences; [FrontendSessionTests][tfront]: `familySelectionBSIM45AndExactSourceRemainInspectable`; [PDK admission tests][tpdk]; [original nfet TT test][tsky] | E1, E2, E4F, E4H, E5S, E5R, E5H | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R04 | Parser/Lowering/Devices/Analysis responsibility split | [ParserSPICE][parser]: [SPICEParser][parserimpl]; [Frontend][frontend]: [session][session]; [Preparation][prep]; [Analysis][analysis] | [MOS declaration intake tests][tintake]; [MOSStageAdmissionTests][tstage]: resolved/legacy refusal; [Native composition tests][tnative] | E1–E4F, E4N, E4A, E5R | G5 verified by E5R; G2 actual analysis matrix. |
| R05 | External comparator and discrepancy layers | CoreSpiceProcessBackend: [NgspiceExternalProcessBackend][ngspice] under the [package boundary][master]; [Native execution][native] owns actual Native evidence | [NgspiceExternalProcessBackendTests][texternal] owns external process behavior; captured BSIM comparator methods and provenance are indexed above | E3/E4B captured fixture comparison; no new live external invocation, E5R | G2 preserves stated reference transformations and discrepancy layers; E5R reconciles composition. Any new comparison is conditional. No physical accuracy escalation. |
| R06 | Retain declaration order/include/scope/source | [ParserSPICE][parser]: [SPICEParser][parserimpl]; [Declarations][decl]: [builder][builder] | [MOS declaration intake tests][tintake]: ordered duplicate roles/locations and nested functions; [MOSSnapshotTests][tsnapshot]: indexed publication retains source order | E1, E2, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R07 | Separate duplicates from geometric overlap | [Selection][selection]: [resolveMOS][resolve] | [MOSSelectionTests][tselect]: strict duplicate outside geometry; current-geometry overlap ambiguity; pinned duplicate-card order | E2, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R08 | Explicit precedence and ambiguity failure | [Selection][selection]: [policy][policy], [resolveMOS][resolve] | [MOSSelectionTests][tselect]: exact-name priority, strict current-geometry ambiguity and duplicate refusal | E2, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R09 | Choose owning family scope first; no parent repair | [Selection][selection]: [resolveMOS][resolve]; [Evaluation][eval]: [invocation graph][graph] | [MOSSelectionTests][tselect]: `nearestFamilyRefusalDoesNotFallbackToParentExactModel`, nonlexical caller model refusal | E2, E4F, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R10 | Exact/family syntax and scoped priority | [Selection][selection]: [policy][policy], [resolveMOS][resolve] | [MOSSelectionTests][tselect]: exact priority, family bins and first same-name pinned card; [FrontendSessionTests][tfront]: family 4.5 source join | E2, E4F, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R11 | Forward/local/actual/parent/cycle consistency | [Evaluation][eval]: [graph][graph], [expression evaluator][evaluator] | [MOSInvocationTests][tinvocation]: defaults, actual winners, caller self-reference; [MOSEvaluationTests][teval]: function and cycle failures | E2, E4F, E5S, E5P, E5R | G1 verified by E5S (nfet TT only); G3 pure snapshot verified by E5P; G5 verified by E5R. |
| R12 | Evaluate each semantic slot once, including RNG | [Evaluation][eval]: [MOSEvaluationSession][evalsession]; [Frontend][frontend]: [session][session] | [MOSEvaluationTests][teval]: binding memo versus distinct slots/invocations; [SPICEFrontendSessionTests][tio]: options/device/analysis/IC single stream | E2, E4F, E4I, E5M, E5R | G4 pilot metrics verified by E5M; G5 verified by E5R. |
| R13 | Separate raw and normalized typed values | [Contracts Values][values]: [ResolvedMOSInstance][resolved]; [Selection][selection]: [resolveMOS][resolve] | [MOSNormalizationTests][tnorm]: schema scaling retains supplied values and separate normalized geometry; [MOSValueTests][tvalues] | E1, E2, E5S, E5P, E5R | G1 verified by E5S (nfet TT only); G3 pure snapshot verified by E5P; G5 verified by E5R. |
| R14 | Parameter-specific units | [Schema][schema]: [MOSParameterScale][scale], [MOSParameterDefinition][parameter] | [MOSSchemaTests][tschema]: exact setter rules and area underflow/overflow; [MOSNormalizationTests][tnorm]: role-specific scale | E1, E2, E5S, E5R | G1 verified by E5S (nfet TT only); G2 physical comparison under matching units. |
| R15 | Omitted versus supplied; no invented scaled default | [Schema][schema]; [Contracts Values][values]: [ResolvedMOSInstance][resolved] | [MOSSelectionTests][tselect]: omitted exact dimensions remain absent; [MOSSchemaTests][tschema]: no guessed dimensions; [MOSNormalizationTests][tnorm] | E1, E2, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R16 | Selection geometry versus physical W/NF/M | [Selection][selection]: [resolveMOS][resolve]; [Schema][schema] | [MOSNormalizationTests][tnorm]: real NF, multiplicity and role scale; [MOSInspectionTests][tinspect]: subnormal divide-before-scale boundary | E2, E4F, E5S, E5R | G1 verified by E5S (nfet TT only); G2 supported-release physical W/NF/M results. |
| R17 | Model bounds/coefficient/BINUNIT independent of deck scale | [Selection][selection]: [resolveMOS][resolve]; [Schema][schema] | [MOSNormalizationTests][tnorm]: model coefficients/bounds unscaled; [MOSSelectionTests][tselect]: selection under held bounds | E2, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R18 | Justified endpoints/overlap/gap/rounding/tolerance | [Selection][selection]: [policy][policy]; [inspection][inspect] | [boundary matrix][tboundary]: adjacent strict endpoints, gaps/interior overlaps, pinned exact tolerance and invalid visited bounds; [MOSSelectionTests][tselect]: closed bounds/missing bounds; [MOSInspectionTests][tinspect]: original subnormal scale | E2, E5P, E5S, E5R | G1 verified by E5S (nfet TT only); G2 separately justified numerical tolerances, indexed above. |
| R19 | Invalid candidates fail typed | [Selection][selection]: [resolveMOS][resolve]; [Contracts Values][values]: [MOSResolutionFailure][failure] | [boundary matrix][tboundary]: reversed/missing/nonfinite visited bounds with terminal refusal or profile-defined exclusion; [MOSSelectionTests][tselect]: duplicate/no-match; [MOSNormalizationTests][tnorm]: overflow/positive-to-zero refusal | E2, E5P, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R20 | No undeclared near-bin/interpolation/corner fallback | [Selection][selection]: [policy][policy], [resolveMOS][resolve] | [MOSSelectionTests][tselect]: nearest-family refusal, exact priority and no-match; [MOSPreparationTests][tprep]: exact 4.5 refusal | E2, E3, E5S, E5R | G1 verified by E5S (nfet TT only); G2 comparator cannot authorize substitution. |
| R21 | Immutable selected release/values/declaration/rules/reasons | [Contracts Values][values]: [ResolvedMOSInstance][resolved]; [Selection][selection]: [inspection][inspect] | [MOSValueTests][tvalues]: checked retained source/symbols/omissions; [MOSInspectionTests][tinspect]: held random bounds and identity-first refusal | E1, E2, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R22 | Downstream performs no model-name search | [IR MOS instances][irstage]: [MOSInstanceStage][stage]; [Preparation][prep]: [NativeMOSDevicePreparer][preparer] | [MOSStageAdmissionTests][tstage]: legacy dictionaries and unresolved stage refused; [MOSPreparationTests][tprep]: receipt-driven consuming bind | E3, E4N, E5R | G5 verified by E5R; G2 actual prepared execution. |
| R23 | Model/instance roles; no selector overwrite | [Schema][schema]: [MOSParameterRole][role]; [Selection][selection]: [resolveMOS][resolve]; [IR MOS instances][irstage] | [MOSNormalizationTests][tnorm]: ordered aliases/winning raw symbol; [FrontendSessionTests][tfront]: MOS maps empty, IC canonical operands/role admission | E2, E4F, E5S, E5R | G1 verified by E5S (nfet TT only); G2 matching physical input roles. |
| R24 | Distinguish selection/preparation/execution/accuracy | [CoreSpice master][master], [Selection][selection], [Preparation][prep], [Native execution][native] | [MOSNormalizationTests][tnorm]: inspectable 4.5; [MOSPreparationTests][tprep]: typed numerical refusal; [PreparedMOSNativeExecutionTests][tmosnative]: actual sweep | E2, E3, E4N, E5S, E5R | G1 verified by E5S (nfet TT only); foundry accuracy remains unqualified. |
| R25 | Same release/temperature/capability/policy from prepare to bind | [Preparation contracts][prepcontracts]: [MOSPreparationIdentity][prepidentity]; [Preparation][prep]: [PreparedMOSDevice][prepared] | [MOSPreparationContractTests][tprepcontract]: exact identity; [MOSPreparationTests][tprep]: changed conditions/capabilities refuse consuming bind | E3, E4N, E5R | G2 exact conditions for each analysis; G5 verified by E5R. |
| R26 | Typed failure categories | [Contracts Values][values]: [MOSResolutionFailure][failure]; [Preparation contracts][prepcontracts]; [IO preparation][ioprep] | [MOSEvaluationTests][teval]: typed cancellation/limits; [MOSPreparationTests][tprep]: unsupported/storage/condition failure; [SPICEFrontendControlTests][tiocontrol]: exact injected cause | E2, E3, E4F, E4N, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R27 | Diagnostic source/scope/instance/geometry/candidates/reasons | [Evaluation][eval]: [MOSResolutionDiagnostic][diagnostic]; [Selection][selection]: [resolveMOS][resolve] | [MOSEvaluationTests][teval]: rejected incoming request owns diagnostic, truncation/cancellation; [MOSInspectionTests][tinspect]: retained bounds/no reevaluation | E2, E5S, E5R | G1 verified by E5S (nfet TT only); G5 verified by E5R. |
| R28 | Failure atomicity and resource cleanup | [Evaluation][eval]: [eval session][evalsession]; [Preparation][prep]: [prepared owner][prepared]; [Native execution][native] | [MOSSnapshotTests][tsnapshot]: post-reserve poison; [MOSEvaluationTests][teval]: failure after random/no retry; [MOSPreparationTests][tprep]: failed CSR/cancellation leaves nodes unclaimed; [Native budget tests][tbudget] | E1–E3, E4N, E4F, E5M, E5R | G4 pilot metrics verified by E5M; G5 verified by E5R. |
| R29 | One mutable owner, immutable snapshot, binding/RNG isolation | [Evaluation][eval]: [MOSEvaluationSession][evalsession]; [Frontend][frontend]: [session][session]; [Preparation][prep]: [PreparedMOSDevice][prepared] | [MOSInvocationTests][tinvocation]: repeated/nested actual identity; [MOSEvaluationTests][teval]: graph/slot RNG isolation; [MOSPreparationTests][tprep]: consuming bind | E2, E3, E4F, E5P, E5R | G3 pure platform evidence verified by E5P; G5 verified by E5R. |
| R30 | Bounded depth/candidates/work/memory/diagnostics; no truncated success | [Contracts Values][values]: [MOSResolutionLimits][limits]; [Evaluation][eval]; [Frontend][frontend]: [resource envelope][envelope] | [MOSSnapshotTests][tsnapshot], [MOSInvocationTests][tinvocation], [MOSResultBudgetTests][tresultbudget]: cumulative limits; [MOSEvaluationTests][teval]: diagnostic truncation; [Native budget tests][tbudget] | E1–E3, E4F, E4N, E5M, E5P, E5R | G3 pure portability verified by E5P; G4 pilot metrics verified by E5M; G5 verified by E5R. |
| R31 | Independent resolver without external simulator/GPU | [MOSResolution][resolution]: [resolveMOS][resolve]; [Contracts][contracts] portable dependency floor | [MOSSelectionTests][tselect], [MOSInspectionTests][tinspect] execute independently; pure production dependency/portable probes in E2/E3 | E1–E3, E5P, E5R | G3 verified by E5P for exact pure bytes; G5 verified by E5R. No numerical GPU/portable claim. |
| R32 | Boundary/order/case/sibling/nonfinite/overflow counterexamples | [Selection][selection], [Evaluation][eval], [Frontend][frontend] | [boundary matrix][tboundary]: before/equal/after endpoints, gap/overlap and visited nonfinite; [MOSSelectionTests][tselect]: closed touching endpoints; [MOSNormalizationTests][tnorm]: aliases/overflow/underflow; [MOSInvocationTests][tinvocation]: siblings; [IC tests][tic]: case/fallback/control truth | E2, E4F, E5P, E5S, E5R | G1 verified by E5S (nfet TT only); G3 pure proof verified; G5 verified by E5R. |
| R33 | Separate current/charge/derivative/analysis/external/process tolerances | [Devices][devices], [Analysis][analysis], [external comparator source][ngspice] | [BSIM4 integration tests][tbsim4], [BSIM3 integration tests][tbsim3], [Devices physics tests][tphysics] retain their own numerical assertions; these are not foundry-accuracy qualification | E3, E4B, E4A, E5R | G2 local tolerances and captured references indexed above; G5 verified by E5R. Any new external comparison is conditional; process accuracy remains unverified. |
| R34 | Execution evidence only after actual run | [Native execution][native]: [NativeCircuitRun][run], [SPICENativeSimulationRecord][record]; CLI case publication consumes completed evidence | [PreparedMOSNativeExecutionTests][tmosnative]: actual sweep and rerun; [Native composition tests][tnative]: actual execution/refusal | E3, E4N, E5C, E5R | G2 supported analysis completion; G5 verified by E5R. |
| R35 | All IDs mapped to owner/implementation/test/evidence; unverified stays pending | [CoreSpice master][master] and this index; workspace [PROGRESS](../../PROGRESS.md) owns completion | Existing method/event census and source hashes in E1–E4/E5P; this index creates no execution evidence | E1–E4/E5P/E5S/E5M/E5C within stated scopes, E5R | G1–G5 scoped evidence verified; E5R records all 19 caller revisions and cumulative closure. Workspace PROGRESS records the final S5 documentation/test-only commit and task completion. |

## Links to Authorities, Implementations and Tests

Reference definitions below keep each row linked to the existing authority instead
of copying its contract. Evidence claims retain these IDs and the scope of the
artifacts that prove each boundary.

[master]: ../DESIGN.md
[contracts]: ../Sources/CoreSpiceMOSContracts/DESIGN.md
[values]: ../Sources/CoreSpiceMOSContracts/Values/DESIGN.md
[schema]: ../Sources/CoreSpiceMOSContracts/Schema/DESIGN.md
[prepcontracts]: ../Sources/CoreSpiceMOSContracts/Preparation/DESIGN.md
[resolution]: ../Sources/CoreSpiceMOSResolution/DESIGN.md
[decl]: ../Sources/CoreSpiceMOSResolution/Declarations/DESIGN.md
[eval]: ../Sources/CoreSpiceMOSResolution/Evaluation/DESIGN.md
[selection]: ../Sources/CoreSpiceMOSResolution/Selection/DESIGN.md
[frontend]: ../Sources/CoreSpiceLowering/Frontend/DESIGN.md
[parser]: ../Sources/CoreSpiceParserSPICE/DESIGN.md
[prep]: ../Sources/CoreSpiceDevices/MOSPreparation/DESIGN.md
[devices]: ../Sources/CoreSpiceDevices/DESIGN.md
[analysis]: ../Sources/CoreSpiceAnalysis/DESIGN.md
[native]: ../Sources/CoreSpice/NativeExecution/DESIGN.md
[irstage]: ../Sources/CoreSpiceIR/MOSInstances/DESIGN.md
[ioprep]: ../Sources/CoreSpiceIO/SimulationPreparation/DESIGN.md
[pdk]: ../../PDKKit/Sources/PDKSpiceProfileInspection/DESIGN.md
[profile]: ../Sources/CoreSpiceMOSContracts/Values/MOSInputProfile.swift
[release]: ../Sources/CoreSpiceMOSContracts/Schema/MOSModelRelease.swift
[resolved]: ../Sources/CoreSpiceMOSContracts/Values/ResolvedMOSInstance.swift
[scale]: ../Sources/CoreSpiceMOSContracts/Schema/MOSParameterScale.swift
[parameter]: ../Sources/CoreSpiceMOSContracts/Schema/MOSParameterDefinition.swift
[role]: ../Sources/CoreSpiceMOSContracts/Schema/MOSParameterRole.swift
[failure]: ../Sources/CoreSpiceMOSContracts/Values/MOSResolutionFailure.swift
[limits]: ../Sources/CoreSpiceMOSContracts/Values/MOSResolutionLimits.swift
[prepidentity]: ../Sources/CoreSpiceMOSContracts/Preparation/MOSPreparationIdentity.swift
[builder]: ../Sources/CoreSpiceMOSResolution/Declarations/MOSDeclarationSnapshotBuilder.swift
[graph]: ../Sources/CoreSpiceMOSResolution/Evaluation/MOSInvocationGraph.swift
[evaluator]: ../Sources/CoreSpiceMOSResolution/Evaluation/MOSExpressionEvaluator.swift
[evalsession]: ../Sources/CoreSpiceMOSResolution/Evaluation/MOSEvaluationSession.swift
[diagnostic]: ../Sources/CoreSpiceMOSResolution/Evaluation/MOSResolutionDiagnostic.swift
[resolve]: ../Sources/CoreSpiceMOSResolution/Selection/resolveMOS.swift
[policy]: ../Sources/CoreSpiceMOSResolution/Selection/MOSSelectionPolicy.swift
[inspect]: ../Sources/CoreSpiceMOSResolution/Selection/inspectResolvedMOS.swift
[compiled]: ../Sources/CoreSpiceLowering/Frontend/CompiledNetlist.swift
[lowering]: ../Sources/CoreSpiceLowering/NetlistLowering.swift
[session]: ../Sources/CoreSpiceLowering/Frontend/NetlistLoweringSession.swift
[envelope]: ../Sources/CoreSpiceLowering/Frontend/NetlistFrontendResourceEnvelope.swift
[parserimpl]: ../Sources/CoreSpiceParserSPICE/SPICEParser.swift
[preparer]: ../Sources/CoreSpiceDevices/MOSPreparation/NativeMOSDevicePreparer.swift
[prepared]: ../Sources/CoreSpiceDevices/MOSPreparation/PreparedMOSDevice.swift
[stage]: ../Sources/CoreSpiceIR/MOSInstances/MOSInstanceStage.swift
[run]: ../Sources/CoreSpice/NativeExecution/NativeCircuitRun.swift
[record]: ../Sources/CoreSpice/NativeExecution/SPICENativeSimulationRecord.swift
[ngspice]: ../Sources/CoreSpiceProcessBackend/NgspiceExternalProcessBackend.swift
[tintake]: ../Tests/CoreSpiceParserSPICETests/MOSDeclarationIntakeTests.swift
[tvalues]: ../Tests/CoreSpiceMOSContractsTests/MOSValueTests.swift
[tschema]: ../Tests/CoreSpiceMOSContractsTests/MOSSchemaTests.swift
[tprepcontract]: ../Tests/CoreSpiceMOSContractsTests/MOSPreparationContractTests.swift
[tsnapshot]: ../Tests/CoreSpiceMOSResolutionTests/MOSSnapshotTests.swift
[tinvocation]: ../Tests/CoreSpiceMOSResolutionTests/MOSInvocationTests.swift
[teval]: ../Tests/CoreSpiceMOSResolutionTests/MOSEvaluationTests.swift
[tselect]: ../Tests/CoreSpiceMOSResolutionTests/MOSSelectionTests.swift
[tnorm]: ../Tests/CoreSpiceMOSResolutionTests/MOSNormalizationTests.swift
[tinspect]: ../Tests/CoreSpiceMOSResolutionTests/MOSInspectionTests.swift
[tresultbudget]: ../Tests/CoreSpiceMOSResolutionTests/MOSResultBudgetTests.swift
[tprep]: ../Tests/CoreSpiceMOSPreparationTests/MOSPreparationTests.swift
[tstage]: ../Tests/CoreSpiceCompileTests/MOSStageAdmissionTests.swift
[tfront]: ../Tests/CoreSpiceLoweringTests/FrontendSessionTests.swift
[tio]: ../Tests/CoreSpiceIOTests/SPICEFrontendSessionTests.swift
[tiocontrol]: ../Tests/CoreSpiceIOTests/SPICEFrontendControlTests.swift
[tic]: ../Tests/CoreSpiceInitialConditionTests/NodeVoltageResolutionTests.swift
[tnative]: ../Tests/CoreSpiceNativeExecutionTests/NativeCircuitCompositionTests.swift
[tmosnative]: ../Tests/CoreSpiceNativeExecutionTests/PreparedMOSNativeExecutionTests.swift
[tbudget]: ../Tests/CoreSpiceNativeExecutionTests/NativeCircuitBudgetTests.swift
[tbsim4]: ../Tests/CoreSpiceBSIM4IntegrationTests/BSIM4IntegrationTests.swift
[tbsim3]: ../Tests/CoreSpiceBSIM3IntegrationTests/BSIM3IntegrationTests.swift
[tphysics]: ../Tests/CoreSpiceDevicesTests/MOSFETPhysicsTests.swift
[texternal]: ../Tests/CoreSpiceProcessBackendTests/NgspiceExternalProcessBackendTests.swift
[tpdk]: ../../PDKKit/Tests/PDKSpiceProfileInspectionTests/SpiceProfileAdmissionTests.swift
[e1]: ../../.verification/runs/b865-mos-boundary-20261010/s1-closure.json
[e2]: ../../.verification/runs/b865-mos-boundary-20261010/s2-closure.json
[e2p]: ../../.verification/runs/b865-mos-boundary-20261010/s2-portable-green/verification.json
[e3]: ../../.verification/runs/b865-mos-boundary-20261010/s3-closure.json
[e3p]: ../../.verification/runs/b865-mos-boundary-20261010/s3-preparation-portable-green/verification.json
[e4f]: ../../.verification/runs/b865-mos-boundary-20261010/s4-review-adapters-green/verification.json
[e4fr]: ../../.verification/runs/b865-mos-boundary-20261010/s4-recheck-frontend.json
[e4ir]: ../../.verification/runs/b865-mos-boundary-20261010/s4-recheck-io-cli.json
[e4i]: ../../.verification/runs/b865-mos-boundary-20261010/s4-io-exact-encoding-green/verification.json
[e4n]: ../../.verification/runs/b865-mos-boundary-20261010/s4-native-budget-green/verification.json
[e4q]: ../../.verification/runs/b865-mos-boundary-20261010/s4-native-fourier-green/verification.json
[e4b]: ../../.verification/runs/b865-mos-boundary-20261010/s4-bsim-shared-budget-green/verification.json
[e4a]: ../../.verification/runs/b865-mos-boundary-20261010/s4-analysis-shared-budget-green/verification.json
[e4d]: ../../.verification/runs/b865-mos-boundary-20261010/s4-devices-first/verification.json
[e4h]: ../../.verification/runs/b865-mos-boundary-20261010/s4-callers-preview-pdk-override/verification.json

[tboundary]: ../Tests/CoreSpiceMOSResolutionTests/MOSSelectionBoundaryMatrixTests.swift
[tkernel3]: ../Tests/CoreSpiceCompactModelsTests/BSIM3KernelTests.swift
[tkernel4]: ../Tests/CoreSpiceBSIM4KernelTests/BSIM4KernelTests.swift
[tanalysisphysics]: ../Tests/CoreSpiceAnalysisTests/DevicePhysicsTests.swift
[tanalysisac]: ../Tests/CoreSpiceAnalysisTests/ACIntegrationTests.swift
[tanalysistran]: ../Tests/CoreSpiceAnalysisTests/TransientAccuracyTests.swift
[nfixture3]: ../Tests/CoreSpiceBSIM3IntegrationTests/NativeBSIMFixture.swift
[nfixture4]: ../Tests/CoreSpiceBSIM4IntegrationTests/NativeBSIMFixture.swift
[oracle3]: ../Tests/CoreSpiceCompactModelsTests/Fixtures/oracle.json
[oracle4]: ../Tests/CoreSpiceBSIM4KernelTests/Fixtures/reference.json
[aoracle3]: ../Tests/CoreSpiceBSIM3IntegrationTests/Fixtures/analysis-oracle.json
[aoracle4]: ../Tests/CoreSpiceBSIM4IntegrationTests/Fixtures/analysis-oracle.json
[e4nl]: ../../.verification/runs/b865-mos-boundary-20261010/s4-native-exact-encoding-green/verification.json
[e5pn]: ../../.verification/runs/b865-mos-boundary-20261010/s4-exclusive-programs-pure-fixed-green/verification.json
[e5pp]: ../../.verification/runs/b865-mos-boundary-20261010/s5-exclusive-programs-portable-green/verification.json

[e4c]: ../../.verification/runs/b865-mos-boundary-20261010/s4-cli-exact-encoding-green/verification.json
[e5si]: ../../.verification/runs/b865-mos-boundary-20261010/s5-sky130-budgeted-green/integrity-and-command.json
[e5ss]: ../../.verification/runs/b865-mos-boundary-20261010/s5-sky130-budgeted-green/selection-observed.json
[e5mv]: ../../.verification/runs/b865-mos-boundary-20261010/s5-performance/verification.json
[e5ms]: ../../.verification/runs/b865-mos-boundary-20261010/s5-performance/performance-summary.json
[e5c]: ../../.verification/runs/b865-mos-boundary-20261010/s5-cli-process/verification.json
[tsky]: ../Tests/CoreSpiceNativeExecutionTests/Sky130OriginalSourceVerificationTests.swift

[e5r]: ../../.verification/runs/b865-mos-boundary-20261010/s5-cumulative-reconciled.json
[e5ledger]: ../../.verification/runs/b865-mos-boundary-20261010/s4-adopted-revisions.json
[e5pdk]: ../../.verification/runs/b865-mos-boundary-20261010/s4-complete-adoption-PDKKit-normal-10/verification.json
[e5host]: ../../.verification/runs/b865-mos-boundary-20261010/s4-complete-adoption-Xcircuite-normal-151/verification.json
[e5studio]: ../../.verification/runs/b865-mos-boundary-20261010/s4-complete-adoption-circuit-studio-normal-160/verification.json
