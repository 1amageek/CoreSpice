# CoreSpiceCLICore

## Purpose and Scope

The [ExecutionPolicy component](ExecutionPolicy/DESIGN.md) owns explicit finite
caller admission profiles for both batch and prepared CLI entry points.

This SwiftPM library module owns batch/interactive SPICE execution and reproducible
run records. Parent: [CoreSpice](../../DESIGN.md). It has no child design units.

## Responsibilities and Boundaries

Session loads the production deck gate, resolves analysis options, lowers,
compiles and binds, then calls public analysis APIs. Domain physics belongs to
Devices and the OSDI consumer. The CLI owns exact source/model provenance and
completed phase evidence throughout initial and repeated binding.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | CLI artifacts | Developer execution surface | Success records require actual execution |
| [IO](../CoreSpiceIO/DESIGN.md) | depends on | Resolved SPICEAnalysisOptions | One policy source | No implicit model work budget |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | depends on | CompiledNetlist and exclusive session | Final scalar and circuit values | Profile, seed and limits are mandatory |
| [NativeExecution](../CoreSpice/NativeExecution/DESIGN.md) | depends on | Consuming concrete analysis APIs and completed facts | Executable ownership and preparation | No BoundDevice exposure |
| [OSDI](../CoreSpiceOSDI/DESIGN.md) | depends on | Typed model receipts through NativeExecution | Official four-family model integration | Execution is not foundry qualification |

Prepared CLI diagnostic adaptation unwraps `SPICESimulationPreparationError`
and preserves its first resource cause, exact-source failure, parser diagnostic
or resolver failure. Finite invocation and IO capacity errors have distinct stable
codes; messages retain configured/required quantities when supplied by their
owner. Text and JSON output use the same classification. `prepared --json`
accepts the ordinary exact catalog and emits only a completed identity/count
summary after numerical execution; failures use the existing failure record and
exit code 2. No resource policy is increased, no partial result is serialized.

## Architecture

`deck explicit option -> resolved options -> lowering + configured registry -> analysis -> run record`

## Contracts and Invariants

### Exclusive source evaluation and native execution

The CLI explicitly selects `CoreSpiceCLIExecutionPolicy.developerV1` or a caller
policy. Profile, seed, resolution limits, native preparation limits and invocation
resources are mandatory Session inputs. The finite developer policy is an
admission policy, not a hardware safety, speed or model qualification claim.
`--mos-profile` selects the input interpretation; `--seed` selects the root seed
(otherwise the named policy selects 1). Source numerical options remain explicit.

```text
Captured source -> CompiledNetlist (reusable immutable snapshot)
  -> new exclusive session per seed
  -> options -> lower -> analysis / IC / nodeset scalar slots -> finish
  -> immutable LoweredCircuit and numeric analysis settings
  -> fresh PreparedNativeCircuit per run -> consuming concrete analysis
  -> completed immutable facts -> observations / case publication
```

Session never retains executable devices or an expression evaluator. Analysis
fields and node assignments consume the same checked scalar slots as lowering,
before the exclusive session finishes. Monte Carlo reuses only the compiled
source snapshot and creates a fresh session and native owner for every seed.
DC sweep changes only the declared independent source inside the common native
owner; it cannot rebind MOS from parameter dictionaries. Completed phase facts
retain actual source values and selected preparation receipts. Preparation
diagnostics become batch evidence only after a concrete run succeeds. Case
publication resolves MOS origins through the compiled snapshot's checked origin
API and serializes receipt-owned final values; it never reevaluates expressions.
Generic MOS sensitivity refuses with `requiresFreshMOSResolution` until its
perturbations have a fresh source-resolution contract. Non-MOS sensitivity and
the existing broad CLI analyses keep their concrete analysis implementations.

The prepared adapter selects its IO transform ceiling from the named developer
temporary-byte ceiling (64 MiB), independently of the 16 MiB frontend retained
ceiling. The IO envelope for 8192 entries already requires 32 MiB before source
text; a smaller transform ceiling would reject every prepared invocation. Actual
IO and frontend reservations still share the finite resource owner, so their
combined temporary storage can fail below either individual envelope. No ceiling
is silently enlarged during execution.

Monte Carlo transient syntax does not support UIC. Successful MC fixtures contain
no unapplied IC intent; same-session IC scalar proof belongs to the direct frontend
fixture, and unsupported MC UIC is a parser failure rather than discarded intent.
The existing ParametricWaveformData contract requires identical axes across runs.
Seed-dependent schedules may resolve correctly yet fail ensemble validation; the
CLI preserves that typed refusal without resampling or claiming variable-axis
ensemble support. Its successful fresh-seed fixture uses expressions over the same
random binding that produce a common schedule, while geometry varies by seed.

A retained simulation output also retains native preparation and result capacity.
A rerun fixture releases that output before preparing again and retains only the
immutable input, explicit native limits and configuration identity. Retaining both
complete runs is subject to the same shared live-byte ceiling; rerun does not reset
or enlarge the original input's accounting owner.

The CLI does not execute build or qualification policy. The common native owner
owns optical graph construction and executable lifetime. Tests must prove fresh
MC values in circuit and analysis, frontend IC slot reuse, completed source-point facts, exact MOS
origins/final values, typed sensitivity refusal, and finite policy failure without
successful publication.

### Required selected-model receipts

Completed records derive the selected source/model/version binding required by
[case-bound qualification](../../../ToolQualification/DESIGN.md) from the actual lowered and bound
instances and verified input sources, retaining effective geometry, temperature,
analysis profile and original result identity. It must not copy requested model
IDs or infer execution from included declarations. Rebinding observations belong
to their own execution phase. The same lexical declaration may resolve different
numeric model parameters in distinct subcircuit scopes; those consumed instances
belong to separate receipts rather than inheriting the first resolved map. Failed preparation or analysis cannot publish a
successful model receipt. Public CLI execution tests own this proof; changing
record structure alone does not establish the contract.

`LoadedSPICEDeck` retains the bytes consumed by parsing and the declaration
origin inventory. For non-MOS devices, `ResolvedDeviceModel.declarationID` carries exact
selected origins for semiconductor resistors; MOS and OSDI receipts retain their own source binding.
`Instance.modelConsumption` separately records selected source models for all
flattened families and generated FET/URC elements, without altering physical
model-role maps. Unrecorded consumption is distinct from explicitly model-free
lowering and refuses canonical case emission.

`--case-output <directory> --case-id <id>` publishes captured inputs, actual
executable bytes, canonical model receipts and `execution.json` in one new,
immutable directory. Publication is bounded by the captured-input policy and
finite output byte budget. A failed/partial publication cannot produce a success
envelope; an existing directory is refused. CLI does not issue qualification.

## State, Ownership, and Lifecycle

### Completed analysis phases

DC sweep updates only the independent source, and Monte Carlo resolves each seed in a new session. Preparation alone is not evidence of a completed phase. Session
retains the actual plan, consumed model/instance parameters, operating
conditions and seed/source overrides passed to each successful analysis. Phase
records are appended only after that analysis and its required observations
complete; failure or cancellation cannot publish a successful case envelope.
DC aggregate measurements retain their complete contributing point set. Monte
Carlo retains observations for every reported seed. Each observation binds only
to the completed phase(s) it consumed; source value and seed identity are
recorded in phase identity and effective instance conditions. Sensitivity case
publication refuses until its internal perturbations expose complete receipts.

The direct CLI case-output path consumes ToolQualification's canonical schemas
in the host CLI target only. IR, Parser, Lowering and IO stay independent from
ToolQualification. This path emits explicit case ID, actual executable/input
identities, original observations and phase-bound selected-model receipts; it
does not issue qualification or choose physical acceptance criteria. Captured
input availability and output publication are explicit, immutable and bounded.
Case-output v1 CLI policy admits at most 10,000 phases, 100,000 cumulative bound
instance records, 100,000 observation scalars and a conservative 64 MiB retained
history charge (128 bytes per parameter/observation entry plus UTF-8 identities
and vector storage). DC schedules and Monte Carlo iteration counts are admitted
before phase retention; aggregate histories fail before the next append. These
operational ceilings belong to CLI evidence, apply only when case-output is
requested, and may change with the same finite-budget refusal tests. Duplicate emitted metric identities refuse canonical output rather than replacing
a completed observation. Measurement identities, retained contributor handles and the repeated UTF-8 phase
inventory expansion are charged before insertion; a conservative JSON bound allows
six encoded bytes per UTF-8 byte plus finite numeric/reference envelopes. Publisher
pre-admits receipt input duplication, instance/model numeric maps, execution
metric-to-phase expansion and availability before serialization. Publication
admits at most 256 MiB including exact captured inputs, executable and all outputs.
Serialization materializes at the bounded output boundary. The destination is
published by exclusive atomic rename only after canonical execution/receipts and
availability inventory exist; partial staging cannot be mistaken for a case.
Cancellation is checked per retained instance/output boundary and immediately
before final rename, with staging cleanup on refusal.
Source capture follows the IO contract rather than a second CLI-owned reader.

Public CLI tests must exercise actual static model calculations, DC source updates and
different Monte Carlo seeds, plus failure/cancellation/missing origin and
incomplete output publication. Primary/oracle assessment and direct host/release
consumer migration are separately verified by their owners.

Session is a caller-owned value. Bound model shared state retains its existing
common Mutex owner; CLI introduces no mutable global or platform synchronization
branch. Each public analysis owns cancellation and transient-session cleanup.

## Failure, Concurrency, and Constraints

No unknown version/model failure becomes a successful fallback. CPU SparseLUSolver
and ComplexSparseLUSolver are the actual electrical execution path in Session;
the electrical CLI does not import or depend on CoreSpiceBackend. Its optional
photonic product remains separately available. This evidence is host CPU only.

## Verification and Change Impact

CoreSpiceCLITests owns actual batch success, model provenance and typed failures.
Classic MOS tests cover Levels1/2/3; OSDI adapter/Native/CLI suites own the four
external compact-model families and complete saved-result validation.

## Prepared Native Command

`prepared` explicitly captures declared catalog files once under finite read,
copy/hash and invocation policies. Include/library route arguments grant exact
lookup availability. Parsing, context, source settings, binding and numerical
dispatch belong directly to the [IO preparation](../CoreSpiceIO/SimulationPreparation/DESIGN.md)
and [NativeExecution](../CoreSpice/NativeExecution/DESIGN.md) owners. The CLI has no
prepared-lane numerical dispatch algorithm and no implicit filesystem include search.
The same retained native owner is executed after preparation; an immutable output
reports computed identities and actual completion counts. Ordinary batch and interactive analyses use the same source evaluation primitives and native preparation owner, while retaining their broader analysis grammar.

The CPU same-owner behavior, real catalog/library parse, and original-file mutation
refusal are verified by
[PreparedCLIExecutionTests](../../Tests/CoreSpiceNativeExecutionTests/PreparedCLIExecutionTests.swift).
The finite CLI developer policy is versioned in the command, enters effective
native configuration identity, and does not claim workload/model qualification.

## Source Diagnostics and Actual Execution Admission

Batch and REPL consume the source-admitted deck defined by
[IO](../CoreSpiceIO/DESIGN.md#source-intake-and-selected-execution-admission), retain
whole-source diagnostics and use actual options/overrides/seed in one lowering and
binding path. Included unsupported declarations remain diagnostic facts and cannot
produce model receipts without actual selected execution. Root blocked controls
continue to fail at intake. Unsupported selected model versions now expose their
actual numerical preparation code; source coverage is not that authority.

Case publication uses the same captured input graph and actual completed phase
instances. A successful ideal circuit with unused Q/C definitions has model-free
receipts; selecting unsupported Q/C must produce no completed case. CLI tests own
these actual execution boundaries and the unsupported-version diagnostic migration.

### Numerical fixture capacity versus policy ceilings

Source `tranmaxscalars` remains the explicit saved-scalar operation ceiling. It
does not request allocation of that many values. The fixed CLI byte ceilings are
unchanged; [native execution](../CoreSpice/NativeExecution/DESIGN.md#incremental-result-capacity-ownership)
admits preparation and actual result capacity separately. The numerical regression
fixture retains its original finite policy and input digests. Complete validation
runs all CoreSpiceCLITests, including the real executable's 31-case regression
corpus, without a numerical-suite exclusion or fixture-cap reduction.

Both ordinary and prepared CLI adapters pass the resolved numerical matrix
dimension ceiling into native preparation. A source override is preserved rather
than hidden behind a second hardcoded 256-row ceiling. The named default remains
256, and every requested topology still has to fit the unchanged native byte
ceiling, temporary ceiling and shared invocation quota. Dimension is counted
using non-ground MNA rows; policy maxima do not allocate a maximum-size matrix.
MOS private rows come from the single prepared receipt before compiler admission;
the preparation byte envelope does not increase logical matrix dimension.

## Removed Native Compact-Model Evidence

Public native BSIM preparation/diagnostic DTOs, batch initializer parameters,
Session completion arrays and encoder fields are removed. Native MOS Levels1/2/3
retain generic consuming preparation and source-backed receipts. Official BSIM
families execute through the OSDI route; their existing batch schema3–7,
prepared schemas, identities, phase facts, source artifacts, physical gates and
finite quotas remain unchanged.

An input-only compatibility check preserves current OSDI records previously
encoded with unconditional empty native-model fields. It accepts only
`bsim4Models: []`, `bsim45Models: []`, a typed Bool for
`bsim4NoisePreparationRequested`, and absent/null `bsim4PreparationPolicy`.
The former flag represented parsed `.noise` analysis intent for every backend,
including OSDI; true alone is not native-model execution evidence. Its value is
validated and discarded without restoring a field or backend. Empty arrays are
checked through an unkeyed container without decoding removed DTOs. Any nonempty
array, nonnull policy or wrong JSON type fails with `DecodingError` identifying
the removed native backend. These keys have no output or execution route; new encodings omit
them completely. This compatibility does not claim a native BSIM execution.

```text
saved current OSDI3–7 + exact empty legacy metadata -> validation -> current record
saved native BSIM evidence or malformed legacy metadata -> explicit decode failure
new classic/OSDI execution -> current record -> JSON with no native BSIM keys
```

`RunRecordTests` owns old-empty compatibility, output-key absence, roundtrip and
forged legacy refusal. `OSDIAnalysisCLIExecutionTests` cold-reloads actual OSDI
noise results with legacy empty arrays and true intent, checks exact complete
record equality and omitted keys on re-encoding. Actual OSDI suites retain full phase/identity/all-point
persistence checks. No schema version is changed solely by removing obsolete
empty metadata, and no old native-model execution is reconstructed.

## D3 Resolution Diagnostic Lifetime

The [diode resolution owner](../CoreSpiceLowering/DiodeResolution/DESIGN.md)
defines bounded source-backed failures. The direct CLI lowering path transfers
its frontend reservation into the IO diode failure wrapper before throwing, so
accounting survives until diagnostic conversion releases its compiled source.
07C supplies the explicit developer/override diode profile and checked numerical
preparation described below.

## 07C Diode and Original Evidence Admission

Parent CLI composes [DiodeEvidence](DiodeEvidence/DESIGN.md) and
[MetricEvidence](MetricEvidence/DESIGN.md); their documents own schema projection
and original metric definitions. developerV1 explicitly selects genericDiodeV1,
with --diode-profile coreDiodeV1|genericDiodeV1 override and a retained finite diode
preparation envelope. Both ordinary/REPL and prepared command pass that profile
into the same source lowering; every numerical operation passes its actual DC/AC/
transient/noise capability union into preparation. No descriptor bypass is restored.

```text
capture/compile -> freeze conditions -> resolve selected profile -> prepare/consume
 -> complete actual analysis -> typed receipts + metric definitions -> atomic publish
```

Generic op/DC/AC/tran/noise/TF/PZ/Fourier/seeded MC retain their existing concrete
algorithms. DC and AC sensitivity create role-qualified checked numeric diode
perturbations and fresh executable owners; original declaration/environment identity
is retained as the basis, while perturbed ordered-source evidence is explicitly
false. The existing source-level MOS sensitivity refusal remains independent.
Case sensitivity remains an explicit refusal until complete perturbation receipts
exist; it never emits a successful original case containing baseline-only receipts.
Unsupported model law/features, limits, cancellation and failed numerical schedules
publish no completed model/case receipt. The prepared-source command retains its
existing op/DC/transient schedule subset, while the common native API supplies the
other existing analyses. No portable numerical or physical qualification is implied.

Verification: DiodeCLIAdmissionTests owns actual ordinary/prepared success and
unsupported/refusal/reload; PreparedDiodeNativeExecutionTests owns exact native
settings digest, typed executed receipts and retained-source rerun; existing case
and CLI suites recheck affected original publication. Actual built binary commands
execute the declared supported analysis matrix and inspect generated/reloaded output.

## S3 OSDI Native CLI Adoption

```text
explicit --osdi-catalog schema1 JSON -> checked host catalog + exact artifacts
 -> explicit typed lowered N instances -> same NativeCircuitPreparer
 -> same DCAnalysis .op -> waveform + completed exact binding records
```

The optional catalog is a host input carrying exact artifact reference/path,
descriptor selection, model/instance-scoped typed assignments, explicit previous
state, and finite loading/preparation/evaluation policy. The native host owner
acquires artifacts without invoking a compiler. Batch and prepared commands
supply the same typed values to source lowering and native preparation; .op is
the only admitted OSDI analysis. Unsupported analysis, unknown catalog schema,
artifact drift, wrong descriptor/type/scope or numerical failure cannot publish
a completed OSDI output.

Completed records derive exact artifact/descriptor/scoped assignments, actual
frozen Kelvin environment and preparation identities from the consumed native
owner. Host JSON projection is separate from portable IR. Saved records are
inspection evidence; rerun requires fresh checked native preparation from the
retained source and catalog. Tests execute both command paths and reload actual
waveform/JSON artifacts; source parsing or record shape alone is insufficient.

### S3 Generic Catalog and Completion Records

Catalog schema1 requires `libraryRootPath`, `stagingParentDirectory`, exact
`artifacts` (reference, relativePath and accessBudget), `instances` (exact normalized
flattened instanceName, modelName, artifact reference, descriptor index/name,
modelParameters, instanceParameters and previousState), loadLimits,
evaluationLimits, maximumInstanceCount, maximumAdapterBytes and tolerances.
Parameter entries explicitly state name, scope, type and value. No device-family
enum or inferred numeric kind is introduced. The named CLI input ceiling is 4 MiB;
all foreign load/workspace bounds remain explicit catalog inputs. Root paths are
absolute availability; artifact relative paths remain capability-scoped.

Batch and prepared accept `--osdi-catalog`; prepared additionally accepts `--csv`
to save its actual completed waveform. Existing non-OSDI output schemas remain
unchanged through optional additive `osdiModels`. Every emitted OSDI model record
has strict schema1 and profile `nativeOSDI.op.v1`, and projects completed native
execution facts: exact artifact/descriptor, typed requested and actual resolved
parameters, explicit previous state, effective Kelvin and raw-node/global-row
mapping with units. Optional `osdiVariables` joins actual compiled rows to observed
source net/branch identity, units and actual finite values from the completed full
waveform before output projection. Saved raw/global candidates therefore do not
depend on CSV display-column order, omitted variables or display-name inference.
Existing `.save`/`.print` selection and ordering remain waveform presentation
semantics. A subset/reorder regression verifies both retained complete values and
the separately selected CSV. Requested catalog entries alone cannot create receipts.
Only actual `.op` is admitted; Monte Carlo and case qualification publication are
outside this initial profile and fail explicitly. Completed records are inspection
evidence; rerun requires fresh digest-checked native acquisition.

Catalog/schema/type/descriptor/artifact/analysis failures occur before waveform
publication. Retained runtime configuration opens and closes a fresh root
capability per load. Tests use bounded subprocess polling and never perform a
redundant blocking `waitUntilExit` after observing termination. Available-family
execution evidence is scoped to its exact artifacts; missing SOI source permission
continues to block an all-four-family qualification claim.

## S4 Complete OSDI Analysis Evidence

This section supersedes the S3 operating-point-only admission. The unchanged
schema1 typed catalog feeds the same NativeCircuitPreparer and existing AC,
Transient and Noise analyses. Prepared dispatch consumes the IO analysis contract;
CLI never computes model equations, integration history or noise transfer.

```text
exact source/catalog -> native analysis -> actual OP + outer completed phases
 -> full pre-projection execution record -> selected CSV + canonical JSON
 -> strict reload -> explicit raw-node/global-row joins
```

Dynamic model records use schema2/profile `nativeOSDI.analysis.v2`; schema1
operating-point records remain readable. Phase and instance jointly identify a
receipt. Dynamic execution schema1 separates compiled row identity from waveform
observable columns. AC stores both complex components at every frequency;
transient stores every actual saved sample and accepted integration context;
noise stores actual OP, source index/name/endpoints/residual unit/raw PSD and
output contribution, input quantity and integrated output noise. Noise observable
indices never stand in for circuit rows. UIC retains no fabricated operating point.
Every value comes from completed results, before `.save`/`.print` projection.
Selected identity CSV columns retain explicit indices into that full waveform.
Existing transformed AC controls retain their actual projected descriptors and
complete computed values separately, without inferring a compiled row from a name. Reload
rejects unknown versions, missing/nonfinite values, mismatched dimensions, duplicate
rows/phases/channels, invalid coordinate order and incomplete model mappings.
Noise coordinates must be positive Hz. Canonical source residual units follow
the actual endpoint row quantity (V to A, K to W, branch A to V); ground-only
channels retain their declared unit. Channel output sums and trapezoidal RMS
integrals must agree with saved totals within 64 machine epsilons per arithmetic
term, allowing accumulation-order roundoff while rejecting changed internal links.
These checks do not replace independent model or physical verification.
Transient time-versus-step consistency follows the authoritative
[TransientResult](../CoreSpiceAnalysis/TransientResult.swift) representation bound:
64 machine epsilons times the larger absolute accepted time or step width.
Subtracting adjacent floating-point timestamps is not an exact reconstruction of
an independently retained adaptive step. The original 677-point BULK trace
contains 152 steps rejected by a relative-step-only comparison despite satisfying
the result owner's time representation contract. Saved coordinates must still
exactly match accepted step times, remain strictly increasing, and have finite
positive step widths. Altered widths/timestamps fail reload; no numerical,
allocation, point-count or integration accuracy tolerance is enlarged.

The versioned CLI evidence envelope permits at most one million scalar components
including coordinates, OP, step contexts, raw noise PSD and extra transformed
projection values. Metadata permits 8192 entries per collection and eight MiB
of UTF-8 names/parameter text; JSON escaping is bounded by six times that text
and 64 bytes per numeric component. Checked admission precedes materialization. Numerical,
source and native resource limits remain independently authoritative. Retaining a
plain inspection record cannot authorize execution. Repeated runs release prior
native outputs and use original input, policy and fresh digest-checked library
acquisition. Cancellation and failed PSD/setup/analysis emit no completion or CSV.

Production persistence remains JSON and CSV. Tests compare actual saved/reloaded
real and complex components, units, complete raw/global mappings, OP, accepted
steps and noise channels against the independent S4 oracle for all four exact
model artifacts. Reverse-bias negative PSD references remain explicit failures.
The unchanged UIC counterexample and affected existing CLI regressions recheck
source-to-analysis behavior. No model-family switch or new RAW reader is added.

### Frequency-analysis initial guesses

Ordinary parsed AC/noise and explicit AC overrides forward the same resolved
`.nodeset` voltages to their nested DC solve as prepared execution. Source guesses
remain initial values, never imposed operating-point results. The behavioral
witness uses a one-node resistor/current-source input with a nonzero exact guess
and an explicit one-Newton-iteration budget: the source succeeds with its guess
and fails without it, proving the initial OP path rather than only a final value.
The existing AnalysisSetupTests owns this small built-in-device regression.

### Nested operating-point observations

A completed OP phase consumes the actual nested DCResult waveform. AC/noise/
transient outer phases consume their own completed waveform. The case collector
never labels an outer final sample as an OP observation. The classic MOS
transient source fixture witnesses the distinct initial and final gate values;
Monte Carlo checks exact OP/outer phase order, per-seed receipt equality and fresh
geometry between seeds. This is an observation binding contract, not a second
analysis or a model calculation.

## S4 Precision Transient CLI Composition

[Precision evidence](PrecisionEvidence/DESIGN.md) owns the versioned canonical
high/low CSV companion; ordinary display CSV retains its existing projection and
precision. CLI composition consumes the Native precision contract and the
validated compensated transient result; it does not evaluate model equations or
reconstruct missing low components.

```text
catalog schema2 + exact captured source + caller execution budget
  -> fresh local artifact source + Native precision preparation
  -> completed transient + actual equation policy + cold model receipts
  -> full precision JSON -> rounded display CSV / canonical paired CSV
  -> bounded strict reload -> source, configuration, row and component-bit checks
```

### Inputs and Authority

Catalog schema1 and its ordinary developer policy remain unchanged. Schema2
requires `transientPrecision`: exact worker reference, capability-relative worker
availability and access budget, semantic and numeric profile digests, all
`OSDIPrecisionOptions` fields and precision bits. It also requires an explicit
`executionBudget` with positive finite UInt64 ceilings:

| Field | Owner and use |
|---|---|
| `maximumNativeAllocationBytes` | Native aggregate admission |
| `maximumLiveOwnedBytes` | Source and retained-output live ownership |
| `maximumTemporaryBytes` | Source transforms and serialization coexistence |
| `maximumHashedBytes` | Host SPICE capture, canonical configuration and CLI output-reference digest work |
| `maximumEvidenceBytes` | Serialized complete JSON and paired companion |

Both batch and prepared apply these caller values before creating their source
resources or Native limits. Existing numerical, work and element limits remain
the existing selected policy. Values are not silently enlarged from developer
defaults. Worker availability uses `SPICEOSDILocalArtifactSource`; the retained
source value owns no open descriptor or root capability. Every acquisition owns
its fresh session and root cleanup. Retained reruns reacquire the original exact
worker and model with the same explicit policies.
The schema2 CLI profile admits source-declared transient analysis only. Batch
uses the same typed prepared composition over its already captured source owners;
it does not reread source paths or recreate Native configuration hashing.

### Durable Precision Record

Precision transient completion uses batch/prepared envelope version4 and
`osdiExecution` version2. Its required `precision` version1 block contains the
following fields; ordinary execution version1 remains readable.

| Field | Meaning and source |
|---|---|
| `configurationSHA256`, `algorithmIdentity`, `solverIdentity` | Actual completed Native configuration, algorithm and solver |
| `legacyBaseDigest` | Native-owned base commitment for cold configuration verification |
| `executionBudget` | The five explicit caller ceilings |
| `sources` | `rootKey`, unique `captures` and ordered actual `occurrences` |
| `settings` | Actual selected analysis, seed, convergence/transient settings, numerical limits, initial conditions and node sets |
| `equationPolicy` | Completed transient rows with kind, variable and equation absolute tolerances |
| `coldModels` | One actual precision preparation receipt per instance |
| `solutionLow`, `highBits`, `lowBits` | Full point-major compiled-row components; existing `real` is high |
| `coordinateBits` | Original binary64 endpoint bits; endpoint low is explicitly zero |

Each source capture has `key`, complete `reference` and exact `bytes`; occurrences
retain source key, occurrence/parent IDs, statement byte offset and ordinal,
dependency kind and selected/parent sections when available. Prepared uses the
actual checked-source owners and occurrence collection. Batch retains the actual
loaded capture owners and dependency events once. Exact source bytes, rather than
inferred R/C/L/source values, allow an independent reader to replay the source.

Each cold model has `instanceName`, `program`, `workerReference`,
`numericProfileSHA256`, `options` and `precisionBits`. `program` contains
`modelReference`, `descriptorIndex`, complete `topology`, `programBytes`,
`setupBytes`, `programSHA256`, `setupSHA256` and `semanticProfileSHA256`.
The existing completed model records provide raw-node/global-row mapping and
units; the precision program topology provides the active/raw mapping. Cold
receipts occur once per instance, not once per phase or accepted point.

`bytes`, `programBytes` and `setupBytes` are typed Data encoded as canonical base64
JSON strings, not arrays of JSON numbers. Reload bounds the encoded and decoded
length before allocation, validates canonical encoding, byte count and SHA-256,
and rejects incomplete or mismatched receipts. Lower-owned arrays remain retained;
one charged Data conversion occurs only at this cold artifact boundary.

Accepted steps retain their existing endpoint, method and high interval fields,
plus `timeStepLowComponent`, `previousTimeStepLowComponent` and the original bit
patterns of every time/interval component. Public compensated-value operations
validate normalized pairs and the exact difference of the selected binary64
endpoints. A high-plus-low sum is never substituted for either component. An
actual ordinary nested OP keeps its declared binary64 representation; no precision
OP or phase count is fabricated. Completed transient equation tolerances come
from `NativeCircuitExecutionFacts.equationPolicy`, not units or defaults.
The first accepted step requires backward Euler with no preceding interval.
The optional previous interval describes available integration history, as defined
by the [Analysis owner](../CoreSpiceAnalysis/DESIGN.md). Later backward Euler may
have no history after a reset; trapezoidal requires it. Whenever supplied, the
complete high/low interval and its bits equal the preceding accepted interval.
The actual preceding interval always remains available in that earlier record.

The completed outer envelope converts its checked source, settings, ordered rows,
equation policy and cold model projection to Native-owned configuration facts and
calls `NativePrecisionConfigurationVerification`, whose commitment is owned by
the [Native contract](../CoreSpice/NativeExecution/DESIGN.md#native-owned-precision-configuration). CLI does not reproduce its
framing or replace it with a JSON checksum. Intrinsic execution-body decoding
checks geometry and local links; only outer decoding with completed model receipts
performs full Native configuration verification. The expected artifact digest
remains the external authenticity boundary. Ordinary Native identities are unchanged.

### Presentation, Ownership and Refusal

Full JSON is authoritative for complete paired coordinates, source, configuration,
model receipts, names, units and accepted history. Existing waveform/CSV output
is explicitly a rounded binary64 presentation. An optional `--paired-csv` companion
stores complete canonical rows by default or an explicit identity-row subset/order.
Display-derived differences, magnitudes and phases do not acquire invented low
components. The companion uses the same configuration digest and explicit row
indices; CLI atomically saves, reads, decodes and checks every component bit,
endpoint and row against full JSON before claiming a completed artifact.

Admission counts retained source bytes, cold program/setup conversion, complete
pair/bit arrays, metadata, JSON escaping/base64, selected companion buffers and
save/readback coexistence before materialization. Native/adapter and source
budgets remain independently enforced. `maximumEvidenceBytes` bounds serialized
evidence, not the process RSS. Inspection reload cannot authorize resumed runtime
state; execution requires fresh checked preparation.
Every source occurrence's repeated key/section metadata contributes to the
serialization bound. Before decoding any numeric plane, aggregate high/low/bit
ownership is admitted together with retained source and cold bytes. Per-plane
limits cannot substitute for this aggregate check.

Unknown versions, missing components or receipts, nonfinite/unnormalized pairs,
bit/value drift, exact-interval mismatch, duplicate/missing rows, source or digest
drift, configuration mismatch, invalid policies, resource exhaustion, cancellation
and worker/setup/cleanup failure cannot emit a completed precision record or paired
companion. Primary and cleanup causes remain observable through Native failures.

### Verification and Change Impact

The OSDI CLI target owns actual batch/prepared executable paths for all four exact
models, full JSON/paired CSV save-read comparisons, source/configuration binding,
sub-ULP and signed-zero components, endpoint/interval audit, selected/reordered
rows, fresh retained-input rerun and repeated-run ownership. Focused corruptions
change each internally linked field and must fail strict reload. Actual worker,
model, capability, budget and cancellation failures must publish no completion.
Independent replay consumes the exact saved sources, actual equation policy,
program/setup, row mappings and complete pairs. Existing ordinary CLI regressions
verify compatibility after source freeze. Changes to Native precision receipts,
compensated result validation or the paired codec require rechecking this
composition; lower numerical qualification is not duplicated here.

The conservative JSON bound includes variable complete-envelope metadata (invocation,
producer, artifact descriptors, measurements and display variable names) before
encoding. Precision records contain no legacy model evidence. Prepared publication
serializes and strictly reloads the complete record before writing companions;
batch serialization failure removes this attempt's published precision outputs.
Compiled row name, kind and unit are mapped directly to Native's ordered
`CompiledRow` facts and verified with the same configuration commitment.

Precision publication preflights resolved local path identities and existing file
identities before writes. Source captures, the catalog, model images and worker
are protected inputs; distinct output roles cannot alias each other. Output data
is staged, charged for digest work on the original shared resource owner, and
referenced in a complete strictly reloaded JSON record before publication. Batch
uses this gate with or without JSON presentation. The Session retains only the
actual prepared input/limits/runtime for a fresh same-analysis Native run; failed
reruns preserve the prior complete observation and its ownership reservations.

The precision profile publishes immutable outputs: an existing destination is a
 typed refusal. Ordinary overwrite behavior is unchanged. Each precision command
uses fresh output paths; an OS no-replace hard-link publication guards the final
check against races and filesystem name aliases. Rollback removes only links
created by that attempt. Staging files remain private siblings until the complete
record has passed serialization and strict reload.

Model and worker acquisition hashes belong to their explicit artifact access
page/byte/work budgets; program/setup hashes belong to precision program/mapping
caps and bounded evidence validation. Those lower APIs do not consume the Host
source-accounting owner, so `maximumHashedBytes` is not a global hash-work claim.
See the [Native execution](../CoreSpice/NativeExecution/DESIGN.md) and
[OSDI adapter](../CoreSpiceOSDI/DESIGN.md) acquisition contracts.

`previousTimeStepSeconds` and its low component describe available integration
history, not an unconditional chronology link. Analysis resets that availability
after a breakpoint and uses checked backward Euler; later BE steps may therefore
carry all previous-interval fields absent. TR requires the complete previous pair,
and any supplied pair must match the preceding accepted interval bit for bit.
The accepted-step endpoint sequence independently retains chronological history.

### Canonical DC persistence

Prepared and batch completion envelopes include `nativeDCResult` for completed
compensated operating-point and source-sweep analyses. Binary64-only records retain
their existing envelope versions; the native stored value is available directly. New envelopes carrying this field use
schema version 5; legacy versions remain readable with their existing binary64
semantics. Version 5 requires the DC field and matching completed analysis/point
counts. The field uses the NativeExecution-owned stored DC contract and preserves
normalized high/low bits independently of waveform projection. Actual batch OP
retains its `DCResult`, and source sweeps retain every point before conversion.
Existing run input/configuration identity owns provenance; the DC value does not
duplicate those identities. No OSDI transient precision receipt is attached to DC.

```text
actual CLI OP / DC sweep -> retained canonical DC -> v5 JSON -> strict reload
                       -> projected waveform -> ordinary CSV (binary64 display)
```

CSV / RAW / waveform summaries contain projected binary64 values; canonical JSON
is required to recover compensated DC state. Roundtrip tests exercise the actual
batch and prepared paths plus malformed pair/dimension rejection and legacy read.

Batch DC coordinates use the [IO preparation](../CoreSpiceIO/SimulationPreparation/DESIGN.md#shared-inclusive-dc-schedule)
shared inclusive numeric schedule. The same source therefore resolves to the
same coordinates in batch and prepared output, including decimal endpoints;
nongrid stops never add an overshooting point.

### Sparse solver execution identity

Actual batch and prepared-command completion summaries emit the real sparse
solver's `CoreSpice.SparseLU.SwiftCSC.v2` identity. The optional additive field
is absent on legacy records and remains nil on reload; explicit unsupported
identities are rejected. A batch summary's solver field does not manufacture
Native source/configuration commitments: ordinary Session batch provenance
continues to bind captured input artifacts and invocation, while the prepared
command retains its actual Native source/configuration identity. Precision replay
requires the new identity in both the Native facts verifier and CLI gate. JSON
capacity framing admits the additional field before encoding.

## Release CLI Output and Invocation Integrity

Every batch and prepared invocation validates all output paths against the exact
root/include/catalog/profile input inventory and all other output paths before
creating staging files. Canonical path plus existing device/inode identity rejects
symlink and hard-link aliases. Files are generated at exclusive sibling staging
paths; only a complete successful run publishes the output set using no-replace
links, with rollback on publication failure. Artifact digests describe staged bytes and therefore the bytes published at each
final destination; content references do not carry filesystem locations.

```text
capture input inventory -> reject aliases -> execute every requested phase
 -> stage outputs + digest staged bytes -> publish complete set or roll back
```

The measure command captures bounded CSV bytes once, hashes those bytes and parses
that same capture. A replaced pathname cannot change the measured evidence identity.
The developer policy owns one shared invocation resource ledger, including all
Monte Carlo samples and retained ensemble waveforms; creating a fresh source
resolution session never resets work or storage admission.

Batch source dispatch executes every declared analysis in source order, preserves
all completed phase receipts, and evaluates each measurement in its matching
analysis domain. Every requested measurement must complete; a missing domain or
failed crossing refuses the successful run record and output publication. The last
requested analysis remains the display/export waveform. Fourier retains its
source transient schedule and independent completed execution receipts.

Verification belongs to CLI release integrity tests: input/output aliases preserve
all existing bytes, every published artifact digest matches its final path,
post-capture replacement preserves measure values and identity, multi-analysis
measurements all run or fail, and finite cumulative MC admission releases capacity
when the retained ensemble is released.

Multiple declared analyses use batch schema v6 with a required ordered
`analysisCompletions` array. Each entry owns the analysis name, output summary and
its native DC/OSDI completion evidence; each saved entry is validated against its
own points and model receipts. The top-level single-analysis numerical fields are
absent in v6. Single-analysis v3/v4/v5 contracts remain unchanged. This prevents an
earlier operating-point result from being mislabeled as the last transient result.

## Prepared Run Families

Prepared source orchestration consumes the IO-owned parse-once run family and
prepares one fresh temperature/seed selection at a time. It never performs source
substitution, model perturbation, or numerical dispatch itself. Native execution
owns TF/PZ/sensitivity/Fourier and its fresh-source device binding. Each completed
case retains exact source/configuration identity, actual run-selection metadata,
selected-model receipts, full output values and all requested measurements.

```text
exact catalog -> IO run family (shared owned parse + bounded selections)
  -> each selection -> fresh resolved input -> Native execution
  -> complete case record + full waveform + measures
  -> ordered family envelope -> strict reload -> atomic publication
```

Prepared family schema v6 is separate from batch schema v6. Its case list is
ordered, nonempty and complete: indices, expected count, source identity and every
selection must agree. A failure or cancellation in any case refuses the family
and all outputs. Single prepared case records retain their existing schema2–5
contracts; the v6 family embeds those case completion records with actual
selection and full waveform. CSV publication exports all cases with explicit
case/temperature/seed coordinates, never a last-case-only file. All case snapshots,
serialization and outputs remain charged to the invocation owner.

The compatibility return value exposes the final native output only after the
entire family completes. Before preparing the next case, the orchestrator clears
its previous `lastOutput`; that output is not a fallback after failure. Completed
case DTOs and their complete saved waveforms retain all required evidence under
the invocation budget, without keeping the previous executable input alive solely
for the compatibility return slot. Cancellation and publication failure still
refuse the complete family and leave no successful output set.

Prepared general-analysis case completion uses schema7 for TF/PZ/sensitivity/
Fourier full values, while the surrounding source family remains schema6. General
OSDI model phase receipts use schema3 for `tf`, `pz`, `sens`, `sens-ac`, and
`fourier`; earlier receipt schemas keep their original phase sets. Successful
sensitivity cases additionally retain every Native-owned source reexecution:
exact input/configuration identities, source scalar patches, selected MOS/diode
preparation receipts, and effective case coordinates. A baseline receipt alone
cannot complete this evidence path. The source ledger is consumed only after the
owning sensitivity analysis succeeds.

Family CSV is a long-form complete scalar table with explicit case, ambient and
nominal temperature, seed, analysis, sweep coordinate, variable, real/imaginary
values and unit. It is a family interchange table; individual waveform CSV keeps
its established single-plot dialect. Family JSON encoding pre-admits the selected
finite temporary serialization ceiling, strictly reloads the full envelope, and
transfers the exact resulting bytes into a live reservation before publication.

A prepared family and an ordinary multi-analysis/MC run each create one
`AnalysisExecutionResources` from their first actual resolved numerical policy.
Every case retains its local statistics/output ceilings while sharing cumulative
solve-attempt/Newton/work/dimension admission. Later incompatible source policies
fail explicitly through Native admission. Family `numericalUsage` is independent
from case statistics, and strict reload requires their actual numerical totals to
agree. Source evaluation, output storage and numerical work use their own shared
owners rather than resetting any of them for a fresh seed.

Prepared MC seed priority matches ordinary CLI: an explicitly present `--seed`
(including zero), then the source `.mc` seed, then the request default. Each case
retains the actual base seed, incremented seed, iteration and seed origin. Absence
is represented explicitly and never inferred from a numeric sentinel.

## Original Sensitivity Case Publication

Ordinary sensitivity uses captured sources through the same source-backed Native
binding as prepared execution. The Session's older IR-only binding is not an
execution path for source sensitivity. A completed child observation contains the
actual source parameter replacement, the effective increment consumed by the
algorithm, and the directly solved selected output. DC retains compensated output
pairs; AC retains the original selected complex outputs at every actual frequency.
The Native completion joins these observations to the fresh preparation and model
origins from that child's own source identity space.

```text
captured deck -> source-backed Native sensitivity
 -> baseline physical solve + each fresh child physical solve
 -> joined original source/preparation/solved-output evidence
 -> CoreSpice sensitivity derivation artifact
 -> opaque metric domain reference -> canonical case execution
```

The case publishes physical baseline/child phases and an explicitly derived
sensitivity phase. The derived metric's contributors are its actual baseline and
matching child phase. It does not describe a sensitivity vector as an operating
point or infer a child's solved value from a derivative. Absolute sensitivity
retains its exact source-numeric-unit meaning; unavailable physical units are
explicitly marked. A normalized value for a zero baseline is unavailable and is
never replaced by zero.

A CoreSpice-owned versioned sensitivity artifact owns raw baseline/child outputs,
source/configuration identities, exact patches, model inputs, effective increments
and derivation identity. The existing Foundation artifact references and
ToolQualification metric-definition domain artifact bind it into the case graph.
The canonical Foundation/ToolQualification schema remains unchanged. All added
observations and artifacts share existing case history, serialization, storage,
publication and cancellation owners. Any incomplete child, mismatched origin,
missing observation, failure or cancellation refuses successful case publication.

OSDI DC uses the general schema7 completion with the actual stored DC result and
full waveform, including binary64 runs. Schema4 OSDI point receipts bind each
source name, exact source-value bits and point index to one completed DC point.
Reload requires the full instance-by-point Cartesian receipt set and agreement
between stored DC and waveform coordinates. Native DC without OSDI retains its
existing schema5 contract.

Fourier precision keeps the actual derived Fourier waveform separate from its
underlying complete transient execution in `fourierTransientExecution` of the
schema8 completion. Its schema version requires that trace so removing it cannot
downgrade the completed precision claim to ordinary Fourier. Precision schema2 records the selected `four` analysis and
actual `fourier` completion facts; schema1 remains transient-only. Both high/low
solution components and all model/interval facts remain retained per family case.
Family CSV adds an explicit phase and low-component column for these physical
transient traces. The existing paired CSV dialect identifies one execution only;
a multi-case family requesting it fails before execution and publishes nothing.

Ordinary source sensitivity uses batch schema7 for a single complete source-backed
analysis and keeps multiphase schema6 for declared sequences. Each source-backed
analysis embeds one bounded canonical prepared completion JSON plus its exact
content reference in `CoreSpiceCLIAnalysisCompletion`. The public outer DTO keeps
Hashable value semantics without exposing internal prepared DTOs. Reload verifies
the nested bytes/reference, strictly decodes their schema, and cross-checks source
captures, selected analysis, full waveform and ordered completed child receipts.
The same encoded completion owner supplies case publication, avoiding divergent
regeneration. OSDI sensitivity uses this path and never enters the older AC-only
execution record. Case evidence captures catalog/library bytes as integrity-bound
inputs; OSDI model receipts describe the actual completed baseline/child bindings.

Filesystem output identity checks share one path guard. Case publication owns
case-destination admission and maps only the guard's typed refusals to the existing
CoreSpiceCLICaseError contract before any sibling output staging. File publication
keeps its existing file-error mapping. Exclusive final publication independently
rejects a destination created after preflight.

Sensitivity source patches follow their actual source owner: ordinary devices use
scalar overrides, while OSDI devices use typed model/instance assignments. OSDI
child projection records the actual resolved descriptor index matching the source
parameter alias. Reload requires both the exact scoped real assignment and the
matching consumed descriptor fact. An empty primitive override array is valid for
that typed OSDI path; a primitive child still requires its exact scalar override.

A selected ordinary source sensitivity prepares its IO input before Native
execution and then transfers Session frontend authority to that exact prepared
owner. The previous independently evaluated Session graph remains accounted during
preparation and is released before baseline/child Native foreign owners coexist.
`sourcePreparedInput` retains the replacement compiled graph and effective options;
no compiled graph outlives its frontend admission. Source dispatch precedes ordinary
IR resolution, and declared sequences retain raw parsed commands rather than an
old compiled owner across the transfer. Numerical resources use the actual prepared
effective limits. Default invocation ceilings remain unchanged.

### Transfer-function port classification

The CLI consumes `TransferFunctionResult.inputPortImpedance` and
`outputPortImpedance` as the authority for finite impedance or an open circuit.
General prepared completion schema 7 requires `transferFunction` schema 1 for
actual `tf`, including each schema 6 family member. The record preserves exact
finite gain/impedance bit patterns, explicit open classifications, and exact
captured source artifact references. Missing waveform columns never determine
port classification.

```text
captured source -> native TF result -> typed TF completion -> canonical JSON
                               \-> finite waveform columns -> CSV
                                      ^ exact typed completion validation
```

The saved waveform retains the two explicit port classification options. Gain is
always present; `Zin`/`Zout` are present exactly when their typed port is finite.
All columns remain finite, and their order, descriptors, coordinates, and bit
patterns must match the typed result. Open ports have no numeric impedance cell.
CSV is a finite presentation; the canonical JSON/API retains open-port meaning.

Ordinary declared TF uses the captured-source native execution path and existing
bounded canonical source-completion bytes, shared by batch schema 7 and case
publication. Actual baseline `op` and completed `tf` phases provide the execution
facts; finite metrics link to the same source-completion artifact. The old dynamic
OSDI AC envelope is not used for TF. Schema 3–5 ordinary batch records and old
prepared non-TF records retain their decoding contracts.

Verification owner: `Tests/CoreSpiceCLITests/TransferFunctionPersistenceTests.swift`
covers finite/open actual source solves, exact saved values, strict round trips,
and missing/altered typed facts, classifications, columns, and flags. Four-family
OSDI TF execution remains owned by the OSDI CLI integration suite.


The admitted source Monte Carlo profile accepts only transient, AC and DC inner
analyses. `SPICEParser.parseMonteCarloAnalysis` is the grammar authority; a typed
`MonteCarloSpec` capable of naming other analyses does not establish source CLI
support. TF classification applies to actual declared TF and prepared temperature
families. `.mc ... tf` is outside the current source profile and is not claimed as
an executed or completed capability.

### Original physical-equation failure diagnostics

`SPICEOSDIPhysicalResidualFailure` is a completed numerical attempt that failed
its original physical equation gate. CLI preserves this typed cause through
`SPICENativeExecutionError.numerical` and emits `analysis.physical-residual` at
stage `analysis`, retaining the actual compiled row, equation kind, signed
residual and absolute tolerance with the corresponding A/V/W equation unit.
The message reports the supplied residual and the failed gate without asserting
that a compensated enclosure's center alone exceeded tolerance. Diagnostic
adaptation neither changes numerical admission nor authorizes a successful run.
`PhysicalResidualFailureTests` owns direct/wrapped classification and JSON
round-trip verification; OSDI integration owns actual physical gate execution.

### JSON grammar capacity bound

The pre-encoding visitor bounds the actual `CoreSpiceCLIJSON` format: pretty
printed, sorted keys, and no slash escaping. It counts container punctuation,
newlines and two-space indentation at the JSON value depth, keys and string
escaping, and conservative scalar token lengths. Generic Codable forwarding and
single-value wrappers do not introduce JSON nesting or duplicate structural
charges. Explicit nested containers and superclass encoders contribute their
actual member/element and container syntax. Repeated visits may overcount keys,
but cannot reduce the reservation.

ASCII strings count quotes/backslashes as two bytes and controls as at most six;
ordinary ASCII (including `/`) uses one. Non-ASCII UTF-8 bytes retain a conservative
six-byte allowance, including possible Unicode line-separator escaping. Numeric
values keep a 64-byte bound. Empty containers include their complete boundary
allowance. Overflow and exceeding the existing selected byte ceiling remain
explicit failures before JSON materialization.

This changes the bound's fidelity, not output contents, accepted schemas, product
ceilings or Data/String coexistence multipliers. Independent `JSONEncoder`
comparisons in `JSONUpperBoundTests` cover escaping, Unicode, finite numeric
extremes, empty/large/nested containers, generic forwarding and super encoders.
Actual four-family CMG completion upper/encoded sizes are integration evidence,
not inferred from these isolated grammar tests.

### Explicit RF network composition

`--analysis-index`, repeated ordered `--network-port <source> <reference-ohms>`
and required positive `--network-residual-tolerance` select exactly one source AC
directive for voltage-controlled fixed-bias network extraction. They use the
existing captured-source preparation and Native execution path; ordinary AC and
source grammar remain unchanged. Existing execution-profile ceilings bound RF
ports, frequency points, result scalars, workspace, serialization and hashing.

Prepared network completions use leaf schema 9 with a required typed RF record.
Prepared family schema 6 composes every validated member. Ordinary RF batches use
schema 8 and the exact same canonical completion bytes as case artifacts. Strict
reload binds ordered physical ports/branches/terminals/R0, source/configuration/
solver/model identities, actual OP, all frequency/matrix values, availability,
residuals and pointwise two-port criteria. Removing the RF record cannot downgrade
a successful network completion into an ordinary AC record. Old schemas retain
their previous meanings. Inspection never creates executable authority.

The finite waveform is a presentation of full S/Y columns; canonical RF data is
the authority for conditional Z and stability availability. Dedicated RF CSV rows
carry case, frequency, matrix axes and explicit unavailable reasons. Touchstone is
a standard interchange projection from the same typed result, not source or bias
proof. A single-case file shares existing alias checks, staging and atomic output
publication. Multi-case interchange uses one immutable directory enumerating every
member; no path silently receives only the final case. Cancellation or any failed
member publishes no completed output set. Source/include/catalog/model/profile
paths and every requested output participate in the existing alias preflight.

RF cold import uses `CoreSpiceCLIJSON.networkDecoder(numericalResources:
sourceResources:cancellation:)`. One context spans the complete root, including
all family children and nested batch completions. Ordinary `JSONDecoder` refuses
RF records without that context; it cannot reset quotas independently per member.
The caller separately admits encoded bytes and decoded-value retention. Lower
mathematical validation runs exactly once per decoded RF record and shares
pre-operation cumulative numerical admission and temporary leases through the
existing source accountant. Producer cold verification uses the running CLI's
existing invocation owners. Simulation statistics remain the actual run snapshot;
verification consumes additional owner usage and is not relabeled simulation work.

RF shape validation restores the saved stability fields without recomputing them.
The single admitted lower mathematical pass receives those exact saved fields and
checks their availability and every bit against the reconstructed S matrix. A
finite S or metric mutation fails as `NetworkParameterError.inconsistentSavedPoint`;
malformed metric encodings fail before mathematical work. Presentation validation
does not add an unaccounted second stability calculation.

Touchstone token admission uses the full admitted ASCII wire-byte envelope, which
bounds all header/reference/data/End tokens rather than counting data pairs alone.
This applies to both a single output and each immutable family member.
