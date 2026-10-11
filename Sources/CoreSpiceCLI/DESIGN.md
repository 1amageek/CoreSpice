# CoreSpiceCLICore

## Purpose and Scope

This SwiftPM library module owns batch/interactive SPICE execution and reproducible
run records. Parent: [CoreSpice](../../DESIGN.md). It has no child design units.

## Responsibilities and Boundaries

Session loads the production deck gate, resolves analysis options, lowers,
compiles and binds, then calls public analysis APIs. Domain physics belongs to
Devices and its evaluators. This change owns explicit BSIM4 preparation policy
and immutable qualification provenance throughout initial and repeated binding.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | CLI artifacts | Developer execution surface | Success records require actual execution |
| [IO](../CoreSpiceIO/DESIGN.md) | depends on | Resolved SPICEAnalysisOptions | One policy source | No implicit model work budget |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | depends on | CompiledNetlist and exclusive session | Final scalar and circuit values | Profile, seed and limits are mandatory |
| [NativeExecution](../CoreSpice/NativeExecution/DESIGN.md) | depends on | Consuming concrete analysis APIs and completed facts | Executable ownership and preparation | No BoundDevice exposure |
| [Devices BSIM4](../CoreSpiceDevices/BSIM4/DESIGN.md) | depends on | Native registry and diagnostics | Original Level54 | Successful execution does not assert qualification |

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

Current BSIM4 run records retain instance diagnostics and preparation policy,
but do not provide the complete selected source/model/version binding needed by
[case-bound qualification](../../../ToolQualification/DESIGN.md).
The target record must derive that binding from the actual lowered and bound
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
selected origins for semiconductor resistor and BSIM3/4 physical models.
`Instance.modelConsumption` separately records selected source models for all
flattened families and generated FET/URC elements, without altering physical
model-role maps. Unrecorded consumption is distinct from explicitly model-free
lowering and refuses canonical case emission.

`--case-output <directory> --case-id <id>` publishes captured inputs, actual
executable bytes, canonical model receipts and `execution.json` in one new,
immutable directory. Publication is bounded by the captured-input policy and
finite output byte budget. A failed/partial publication cannot produce a success
envelope; an existing directory is refused. CLI does not issue qualification.

The actual deck option bsim4stressiterations is the caller's positive UInt32 work
budget. Each exclusive Session evaluation resolves one options object used by lowering, native preparation and operating conditions. Each Monte Carlo seed has its own evaluation. The batch
record preserves effective policy separately from physical IR and retains BSIM4
completed-phase preparation diagnostics and immutable maintainer qualification
limitations. Each model record names a completed numerical phase; Monte Carlo seeds retain their own preparation diagnostics.
Missing/invalid policy, unprepared noise topology and invalid noise numerics remain
failed JSON records.

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
merely importing Backend does not execute Metal. This evidence is host CPU only.

## Verification and Change Impact

CoreSpiceCLITests owns actual batch success/effective-policy records and typed
missing/invalid/version/noise failures. CoreSpiceBSIM4IntegrationTests owns public
analysis/session proof. Revalidate existing options/CLI consumers after convergence.

## BSIM4 Noise Execution Provenance

The same resolved SPICEAnalysisOptions noise-preparation choice reaches lowering
and every bind, and is recorded in the batch execution record. Parsed .noise
executes actual public NoiseAnalysis and publishes output/input densities and
integrated output RMS through the existing waveform conversion. Typed refusal
for late unprepared topology, invalid modes/gains/numerics and cancellation
remains failure. Mode1 qualification metadata is never promoted by execution.

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

## BSIM4 4.5 Run Diagnostics

Completed phases retain a separate `CoreSpiceCLIBSIM45Record`: phase, instance,
preparation implementation identity and original bounded diagnostics. Native
records are projected to host Codable values only at the artifact boundary. No
Codable dependency enters the portable evaluator. Unsupported original versions
fail schema admission before execution artifacts can be published.

The completed batch record uses schema v2: `bsim45Models` is required, including
an empty array for a run without 4.5 devices. The v2 fixture and actual CLI
round-trip tests consume this shape; missing release evidence is a decoding
failure, not an inferred empty record. No v1 compatibility decoder is provided.
