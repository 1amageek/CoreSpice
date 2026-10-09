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
| [Devices BSIM4](../CoreSpiceDevices/BSIM4/DESIGN.md) | depends on | Native registry and diagnostics | Original Level54 | Successful execution does not assert qualification |

## Architecture

`deck explicit option -> resolved options -> lowering + configured registry -> analysis -> run record`

## Contracts and Invariants

### Required selected-model receipts

Current BSIM4 run records retain instance diagnostics and preparation policy,
but do not provide the complete selected source/model/version binding needed by
[case-bound qualification](../../../ToolQualification/DESIGN.md).
The target record must derive that binding from the actual lowered and bound
instances and verified input sources, retaining effective geometry, temperature,
analysis profile and original result identity. It must not copy requested model
IDs or infer execution from included declarations. Rebinding observations belong
to their own execution phase. Failed preparation or analysis cannot publish a
successful model receipt. Public CLI execution tests own this proof; changing
record structure alone does not establish the contract.

Current `ResolvedDeviceModel` retains name, type and evaluated parameters but
drops the parsed declaration's source location. Current `LoadedSPICEDeck`
records paths, while `executeBatch` hashes those paths after parsing. These
facts do not establish that a retained model source is the exact content consumed
by the parser. Receipt integration must retain the selected declaration origin
and bind each consumed source to its captured content; a later read of the same
path cannot substitute for that identity. Model names alone cannot disambiguate
same-named declarations in different scopes. Path/availability metadata must
remain separate from content identity. Missing or changed source bindings refuse
qualification, rather than publishing an inferred receipt.

The actual deck option bsim4stressiterations is the caller's positive UInt32 work
budget. Session uses one resolved options object for lowering, initial binding,
source-sweep/MonteCarlo/sensitivity rebinding and operating conditions. The batch
record preserves effective policy separately from physical IR and retains BSIM4
initial-binding structured diagnostics and immutable maintainer qualification
limitations. Each model record names its initial-binding phase; Monte Carlo
rebindings share the policy but their varying diagnostics are not claimed by that
initial snapshot.
Missing/invalid policy, unprepared noise topology and invalid noise numerics remain
failed JSON records.

## State, Ownership, and Lifecycle

### Completed analysis phases: required migration

DC sweep rebinds each point, and Monte Carlo re-lowers each seed. The current
baseline `devices` snapshot is not evidence of those completed phases. Session
must retain the actual plan, consumed model/instance parameters, operating
conditions and seed/source overrides passed to each successful analysis. Phase
records are appended only after that analysis and its required observations
complete; failure or cancellation cannot publish a successful case envelope.
DC aggregate measurements retain their complete contributing point set. Monte
Carlo retains observations for every reported seed instead of attributing the
first seed's measurements to later runs.

The direct CLI case-output path consumes ToolQualification's canonical schemas
in the host CLI target only. IR, Parser, Lowering and IO stay independent from
ToolQualification. This path emits explicit case ID, actual executable/input
identities, original observations and phase-bound selected-model receipts; it
does not issue qualification or choose physical acceptance criteria. Captured
input availability and output publication are explicit, immutable and bounded.
Source capture follows the IO contract rather than a second CLI-owned reader.

Public CLI tests must exercise actual static model calculations, DC rebinds and
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
reports computed identities and actual completion counts. Existing ordinary batch
and interactive analyses preserve their independent API/capability contracts.

The CPU same-owner behavior, real catalog/library parse, and original-file mutation
refusal are verified by
[PreparedCLIExecutionTests](../../Tests/CoreSpiceNativeExecutionTests/PreparedCLIExecutionTests.swift).
The finite CLI developer policy is versioned in the command, enters effective
native configuration identity, and does not claim workload/model qualification.
