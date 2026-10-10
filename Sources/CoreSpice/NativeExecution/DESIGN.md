# Native Prepared Simulation Execution

## Purpose and Scope

Status: implemented Native CPU capability; see supported domain below. Parent: [CoreSpice module](../DESIGN.md).
No children. Own compilation, actual model/device binding and numerical dispatch
for a retained IO preparation; initial profile coverage is `.op`, `.dc`, `.tran`.

## Responsibilities and Boundaries

Move domain algorithm selection out of Xcircuite's CoreSpiceSimulationEngine.
Reuse StandardCompiler, existing device/solver/analysis implementations and waveform
IR. IO owns parsing/settings; host owns output artifact serialization/location,
measurement acceptance and ledger. No new universal Engine or AgentHarness wrapper.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](../DESIGN.md) | parent | Direct native domain API | Result integration | External backend is separately qualified |
| [IO preparation](../../CoreSpiceIO/SimulationPreparation/DESIGN.md) | depends on | Actual graph/CircuitIR/config and retained IC/nodeset | Immutable executable intent | No source reread/reparse |
| [Compile](../../CoreSpiceCompile/DESIGN.md) | depends on | StandardCompiler and topology | Actual node/device binding | Admission ceilings precede construction |
| [Analysis](../../CoreSpiceAnalysis/DESIGN.md) | depends on | Existing DC/transient limits and results | Numerical behavior | No numerical-policy fallback |
| [Devices](../../CoreSpiceDevices/DESIGN.md) | depends on | Actual selected model/device semantics | Physics capability | Loaded declarations are not executed model proof |
| [Host](../../../../Xcircuite/Sources/Xcircuite/ProfileExecution/DESIGN.md) | used by | Prepared plan, observations and output | PDK-before-execution match | Evidence is not release approval |

## Architecture

```text
PreparedSPICESimulation -> compile/bind -> PreparedNativeSPICESimulation
       -> host PDK comparison -> execute same owner -> numerical output + observations
```

## Contracts and Invariants

Implemented separate interfaces:

```swift
public protocol SPICENativePreparing: Sendable {
    func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits)
        throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation
}
public protocol SPICENativeExecuting: Sendable {
    func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput
}
```

NE-01: Preparation compiles the same CircuitIR and resolves actual descriptors,
models, node assignments and analysis binding. Its internal-constructor owner
retains the IO owner, immutable plan/configuration, supported model selection and
effective algorithm/solver identities. Extend IO configuration identity with native
choices and effective numerical limits before host comparison. Capability refusal
occurs before a numerical run; a requested model name is not an observed binding.

NE-02: Execute has no reader, String, filename, source list, parser or replacement
settings argument. Consume the private mutable devices bound once during preparation,
and allocate invocation-local solver state. Independent runs prepare fresh owners
from the copyable record's input. DC points replace only the recorded independent
source target/value; all other devices retain their history; `.tran` passes the
resolved initial voltages, guesses and UIC into TransientConfig. `.op` applies
supported nodeset semantics explicitly; an unsupported assignment/analysis
combination refuses instead of silently ignoring it. `.ic` effects follow the
existing analysis contract, rather than inventing a new initialization rule.

NE-03: Output retains complete actual input/config identities, copyable simulation record,
analysis/point schedule, actual executed model receipts, effective runtime
conditions and numerical completion statistics with waveform IR. Partial points
or cancellation never become completed full-schedule evidence. Host report/CSV
generation observes this output without starting another analysis. A preparation
receipt proves intended bound inputs; executed-model coverage requires run receipts.

## Runtime Flows

prepare -> admitted native owner -> expected-profile match by caller -> execute ->
await actual analysis completion -> verify finite/domain-valid output -> completed
output. Cancellation bridges the caller task to the existing cancellation token;
no detached cleanup task or hidden background run outlives the call. Failure retains
typed cause and releases invocation state without publishing a completed output.

## State, Ownership, and Lifecycle

Immutable IO/plan backing may be shared. Mutable devices, solver workspace,
cancellation and result buffers have one execution owner. Repeated executions use
fresh state and retain parent backing. Budget counters use the existing synchronized
owner; callbacks/I/O are outside locks. No target-specific raw mutable state or
weakened Sendable contract is introduced.

## Failure, Concurrency, and Constraints

Native limits bound compilation/device counts and allocation, sweep points, solver
work, waveform retention and numerical duration. Existing TransientExecutionLimits
own transient semantics; source-intake capacity does not imply numerical limits.
Pre-admit new compile/bind materialization and bound each transformation or return
typed unsupported-resource capability. No fallback changes model, solver, analysis
or backend. This first lane is Native CPU; Metal changes require real xcodebuild
test and are a separate verified capability, not a claim from CPU fixtures.

## Verification and Change Impact

`CoreSpiceNativeExecutionTests` owns actual waveform changes from IC/UIC,
nodeset application/refusal, real supply versus stimulus sweeps, exact prepared
input execution after original files change, configuration drift, concurrent
independent runs, bounded refusal and cancellation. CLI/host integration verifies
direct use of this owner. Existing numerical algorithms are regression-checked
only for the affected paths; repeated grammar/resolver proof is unnecessary.
Implementation adds explicit module dependencies and migrates host numerical
dispatch plus relevant CLI calls. Unsupported remaining host analyses retain an
explicit incomplete marker and cannot claim profile coverage.

## Implemented Native CPU Capability

[SPICENativeSimulation](SPICENativeSimulation.swift) implements both phase protocols.
The internal-constructor noncopyable native owner retains the exact prepared IO
input, compiled plan and private devices bound once during preparation. Consuming
execution transfers these devices into one invocation and creates solver workspace.
Output retains a copyable record without executable owners. Each rerun explicitly
prepares fresh devices from that record's input.

The IO-facing lane currently supports flat two-port R/C/L/V/I, including exact
selected resistor model provenance. The S3 native composition also admits typed
resolved MOS stages; public IO adoption belongs to S4. Legacy MOS model dictionaries
cannot supply numerical authority. This
lane owns `.op`, one-source `.dc`, and `.tran`; it uses the existing numerical
implementations without host dispatch algorithms. DC source override preserves all
original instance ownership/model/branch metadata. Nodeset is passed as the actual
DC initial guess. Transient receives the prepared UIC and IC/nodeset dictionaries.

| Native admission | Contract |
|---|---|
| Compile dimension / devices | Derived node+branch dimension plus eight potential auxiliary nodes per MOS and instance count checked before compilation |
| Compile / bind storage | Dimension² ×256 plus (devices+dimension) ×4096; additionally each MOS maximumRetainedBytes and maximumTemporaryBytes reserved before owner slots, auxiliary arrays or cold setup |
| Numerical topology / work | Existing TransientExecutionBudget admitted against exact compiled topology; DC uses the same shared owner across the entire point schedule |
| Execution storage | Preparation envelope retained once; requested result capacity admitted incrementally before allocation, independently of the saved-scalar ceiling |
| Numerical iterations/output | Existing pre-operation solve/Newton/work/saved-scalar admission, including DC recovery, and complete transient limit enforcement |
| Output | Only after exact complete schedule, finite validated numerical results and final cancellation check; retains its storage reservation |

The compile envelope covers dense LU and sparse factors, adjacency/ordering/tree
workspaces and copied topology structures. The execution envelope additionally
covers numerical trace, waveform materialization, descriptor slots and receipts.
Numerical limits and native ceilings enter `CoreSpice.native-configuration.v1`
alongside the IO configuration digest, algorithm/solver identity and actual ordered
selected device/model declaration identity. Selected declaration identity is framed
by captured content and physical occurrence coordinates, not availability keys.
Native identity uses the IO semantic-encoding helper to preflight immutable framing
against maximumTransformBytes, reserve its exact byte count and emit/hash the same
ordered framing. The upper limit is not an eager temporary allocation. The count
pass reads prepared receipts and captured provenance without preparing/binding MOS,
resolving expressions or mutating receipt collections; receipts remain owned by the
common preparation record. Capacity/cancellation failures release the pending owner.

| Shared mutable state | Storage / isolation | Read / mutation / release |
|---|---|---|
| Invocation capacity/work | Injected resource owner; concrete SPICESimulationResources uses Mutex<State> | Unified charge/reserve APIs, synchronized receipt release |
| Solver/device state | Fresh private preparation owners consumed into one invocation | No external device access; source-only sweep replacement; released at call completion |
| Numerical counters | Existing Mutex-backed TransientExecutionBudget | Pre-operation admission and statistics snapshot |
| Cancellation | Existing Atomic-backed CancellationToken | Task cancellation bridges synchronously; no detached work |

No target-dependent synchronization branches or Sendable weakening are introduced.
Evidence scope is fixed Swift 6.4.0 release on macOS Native CPU. Metal, WASM and
Embedded execution are not qualified by this implementation. Ordinary external
backend and independently exposed analyses preserve their existing semantics.

### Prior non-MOS evidence

The following evidence predates the S3 ownership migration; S3 must reverify the
changed owner and run paths before completion.

Fixed `swift-6.4.0-RELEASE` (`org.swift.640202609131a`), arm64 macOS 27 Native CPU:
`CoreSpiceNativeExecutionTests` registry contains 7 functions; all 7 produced
matching `testStarted`/`testEnded` events, with zero issues (0.016 seconds). Actual
fixtures verify 2V/0V UIC initial waveforms and RC discharge, nodeset reducing the
actual DC Newton iteration count, source versus supply DC sweep schedules and
results, exact condition refusal (including instance TEMP), full library graph
and selected resistor TNOM/model provenance, relocation identities, fresh concurrent
executions, capacity/cancellation/unsupported physics failures, retained-last-copy
resource release and no publication on quota refusal. The CLI fixture changes both
original files after the first run and reuses the same native owner with unchanged
original 2V result and identities. The default Swift build system is required for
this fixed toolchain's Swift Testing runtime; deprecated Xcode SwiftPM test products
that run zero functions are not evidence.

## Single-Owner MOS Preparation Migration

The S3 boundary replaces temporary binding and execution-time re-preparation.
`PreparedNativeSPICESimulation` becomes noncopyable and retains private bound device
owners created once during prepare. Its copyable `SPICENativeSimulationRecord`
retains input, compiled plan, limits, semantic identities and preparation receipts,
not executable owners. Output retains that record only. `execute` consumes the
prepared owner. A second run explicitly calls prepare again from the same resolved
input; it never aliases numerical history from a previous run.

```text
resolved IR -> prepare each MOS once -> UniqueArray<NativePreparedMOSDevice?>
    -> receipt-derived auxiliary allocation -> prepared IR -> StandardCompiler
    -> take each indexed slot -> consuming bind -> private bound devices
    -> consuming execute -> completed output + copyable record
```

Native limits optionally carry explicit `mosPreparationLimits` and
`mosPreparationConditions`; both are required when MOS is present. Non-MOS circuits
need neither. Conditions must match IO ambient/nominal temperature, exact requested
analysis capability and explicit BSIM4 stress policy. No implicit condition change
or re-preparation is allowed. Aggregate execution reservations include actual native
owner receipts and topology allocation before publication. Private auxiliary IDs
are fresh, overflow checked, present in CircuitIR, and cannot collide with diagnostic
node names. A failed stage publishes no partial circuit or executable owner.

All MOS parameters come from `Instance.mos.resolved`; legacy model-name/dictionary
lookup is refused. Non-MOS descriptors keep their existing interpretation. During
DC sweeps only the independent source target is replaced; all MOS bound owners and
cold-setup history remain owned by that execution. The numerical algorithm is
unchanged. Preparation receipts prove preparation; executed receipts are emitted
only after the complete finite numerical schedule and cancellation checks.

The exact Swift 6.4.0 standard library exposes UniqueArray at macOS 27. The package
therefore adopts Swift tools 6.4 and macOS 27, with callers migrated in S4. The local
capability probe compiled, linked and executed noncopyable optional enum slots,
indexed take and consuming binding; no custom unsafe container is introduced.

The immutable record and exclusively consumed owners preserve the same Sendable
and kernel Mutex contracts on all compiled targets. Pure resolution remains
independently portable; numerical preparation/execution evidence is Native CPU.
CoreSpiceNativeExecutionTests verifies fresh reruns, source-only sweep updates,
complete receipts and failure release. CoreSpiceMOSPreparationTests verifies exact
release/conditions/topology and single-owner binding independently of parsing.

### S3 Reservation and Evidence Boundaries

Conservative reserved capacity is distinct from actual payload metrics. Aggregate
compile/execution envelopes retain the admitted topology upper bound and per-MOS
maximumRetainedBytes; temporary admission includes per-MOS maximumTemporaryBytes.
Receipts separately expose actual retainedBytes and peakTemporaryBytes. Neither
reserved capacity nor a preparation receipt proves numerical execution. Completed
executed-model receipts include the actual preparation receipt only after the
complete numerical schedule and final cancellation check.

The source-resource adapter preserves the existing synchronized accounting owner
and charges retainedElements for MOS work. checkCancellation failures become typed
MOS cancellation. chargeWork maps Task cancellation, CancellationError and the
concrete SPICESimulationResources cancelled case to cancellation; other opaque
protocol failures become workLimitExceeded. The source accounting protocol exposes
no further typed cause, so custom owners must use checkCancellation to distinguish
cancellation before work admission.

| Shared state | Native | WASM / Embedded |
|---|---|---|
| Source budgets | Existing injected Mutex-backed owner; unified reserve/charge/release | Same source and Sendable contract; native composition execution not qualified |
| MOS numerical history | Fresh private bound owner; existing kernel Mutex; consume once | Same owner/isolation declarations; target runtime not qualified by S3 |
| DC source overrides | Invocation-local array slot; MOS slots unchanged | No target-conditional state or conformance branch |

S3 direct-stage fixtures own native preparation, exact conditions, reservations,
single cold setup across source sweeps and fresh reruns. These fixtures construct
typed resolved stages independently of parser/lowering adoption and do not qualify
public SPICE-to-MOS integration before S4.

## Shared Native Circuit Composition

S4 moves the S3 prepare/compile/consume-bind path into `NativeCircuitPreparer`.
It accepts resolved CircuitIR, the existing non-MOS DeviceRegistry, explicit
OperatingConditions, native and numerical limits, and the existing synchronized
source resource owner. It constructs the optical graph before publishing one
`PreparedNativeCircuit: ~Copyable`. This owner keeps devices private; its copyable
record exposes plan, conditions, limits, MOS receipts and immutable BSIM4 diagnostics.
SPICENativeSimulation delegates this same composition and retains IO-specific exact
source identity encoding. No caller repeats MOS preparation, compilation or binding.

Concrete DC, AC, Noise, TransferFunction, PoleZero, Transient and Fourier analysis extensions
in the CoreSpice target consume the owner, invoke unchanged analysis implementations,
validate complete results and return NativeCircuitRun<Result> with immutable completed
phase facts. Facts retain both preparation and run reservations, including facts
retained by a point callback when a later point fails. This target placement preserves the dependency direction from CoreSpice
to CoreSpiceAnalysis. There is no generic public execution callback receiving devices.
Transient preserves the analysis's onStepAccepted callback and EventDispatcher.
Fourier consumes the same private state through its existing transient-then-harmonic
implementation, checks numerical limits and bounds harmonic output before execution.
DC source sweeps consume one owner, replace only the selected independent source,
share numerical budget across points, and emit exact point facts after each success.
A callback failure or cancellation prevents completed full-sweep publication.
Cancellation rejected during common admission emits one started/cancelled event
pair for the requested concrete analysis before releasing its owner. Accepted
admission delegates event lifecycle to the unchanged analysis implementation, so
the wrapper does not duplicate lower-analysis terminal events. The untyped source
accounting boundary preserves other failures as .resource(originalError); only
CancellationError and the concrete SPICESimulationResources cancelled case are
classified as cancellation after the task/token check.

Preparation facts are not execution proof. Completed facts have internal constructors
and retain actual instances (including exact source overrides), conditions and MOS
receipts whose resolved snapshots own final values and source provenance. BSIM4
initial diagnostics are immutable preparation evidence. Generic dictionary sensitivity
or Monte Carlo cannot reuse a MOS receipt; callers must supply newly resolved inputs
or receive AnalysisError.requiresFreshMOSResolution before sampling or rebinding.
Concrete operations admit the receipt capability set before numerical work: DC and
TF require DC; AC and PZ require DC plus AC; noise adds noise; transient adds transient.
A mismatched set fails with SPICENativeExecutionError.mosPreparation(.invalidConditions).

All reservations precede allocation and remain retained by inspection/results where
needed. Numerical capacity is finite and explicit for every operation. Existing
solver algorithms and device history synchronization remain unchanged. Native tests
own common preparation, consuming operations, source-only sweep facts, callbacks,
optical graph composition, cancellation and failed-owner reservation release.

## Complete Concrete Numerical Admission

The native preparation record's numerical limits govern the entire consuming
operation. One checked budget is injected into the lower analysis and transported
through embedded DC, recovery, repeated sensitivity/AC solves, linear phases and
saved outputs. Concrete results expose its final statistics. No perturbation or
nested analysis resets the budget.

Fourier admits every harmonic component at its native stride and result dictionary metadata before execution. It shares the transient result-capacity owner, then admits final-period scratch from the actual completed time-point count before postprocessing. The separate scratch lease is released on success, failure or cancellation. Peak live
plus scratch is checked against the native allocation ceiling with overflow checks.
The source resource owner additionally admits those exact reservation capacities.
The lower Fourier owner charges actual completed-sample integration work against
the same budget before allocating postprocessing arrays. Numerical exhaustion,
allocation refusal and overflow publish no completed facts and release owners.

The internal NativeCircuitRun initializer requires the package result-storage
contract and attaches the admitted live reservation to every concrete result.
The public generic run type keeps its Sendable-only constraint. An extracted
copyable result retains capacity after its wrapper/facts are released. Typed nested
results and DC sweep callback point results retain the same lease; the final result
copy releases it. Individual Array/Dictionary extraction and derived materialization
are caller-owned value boundaries, as defined by the Analysis result contract.

NativeCircuitBudgetTests owns the six embedded-Newton counterexamples, aggregate
sensitivity solve refusal, Fourier coexistence refusal, admitted harmonic output
postprocessing work exhaustion, extracted DC/transient/Fourier result lifetime and
retained sweep callback points after failure. Existing
native and BSIM analyses revalidate
physical results after package budget transport changes.

## Original Sky130 Source Verification

The opt-in `Sky130OriginalSourceVerificationTests` uses
`MOS_ORIGINAL_SKY130_ROOT` to locate the unchanged installed sky130A revision.
The public source preparer receives exact checked owners for the original
`sky130_fd_pr__nfet_01v8__tt.pm3.spice` and mismatch corner, with an explicit
caller wrapper supplying TT Monte Carlo switches, micron geometry scale and
W=0.65/L=0.15/NF=1. The wrapper owns those operating inputs; it neither extracts
nor replaces any model declaration or coefficient.

One public `SPICESimulationPreparer` invocation owns options, the shared evaluation
session and lowering. The test verifies selected declaration identity, original
source occurrence and statement coordinates, normalized/selection dimensions,
release and candidate evidence before invoking `NativeCircuitPreparer`. Exact
BSIM4 4.5 must fail with `mosPreparation(.unsupportedRelease(.bsim4_4_5))` before
numerical ownership or execution. This verifies interpretation and refusal,
not BSIM4 4.5 numerical physics. Absent the opt-in environment, the test is skipped.

The S5 external runner records the complete original PDK file inventory and SHA-256
before and after execution; any content or inventory drift invalidates this proof.
The probe writes observed selection facts only when an output path is supplied.
The normal verification driver owns toolchain, timeout, test status and production
source hashes. This contract adds no production fallback or public evaluator access.

## Incremental Result Capacity Ownership

The preparation record owns one conservative compile/solver envelope. Its matrix extent counts non-ground voltage rows plus branch rows, matching CircuitTopology; the ground reference consumes no row or matrix storage. Preparation
admits its simultaneous retained and temporary peak; execution retains that lease
without reserving the same bytes again. `maximumSavedScalars` is an operation
ceiling, never an allocation request or eager retained result reservation. CLI
allocation and source-resource ceilings remain unchanged.

`NativeExecutionStorage` owns the preparation record, result leases and a common
`Mutex<State>`. Fixed schedules admit their requested scalar capacity and facts
before allocation. Adaptive transient storage starts at one point and grows
geometrically, with overflow-checked capacity admission before reserve, append,
device commit or accepted-step publication. The numerical saved-scalar budget
continues to charge actual points; buffer capacity does not change that ceiling.

Result capacity reserves 32 bytes per scalar capacity: a conservative envelope
for Double/Complex payload, simultaneous old/new buffers during growth and
waveform conversion. This is reserved capacity, not measured allocator/RSS usage.
Preparation bytes enter peak comparisons once; result capacity and active scratch
are additive. Fourier scratch is derived from completed points, never the policy
maximum. A refused accounting call poisons this execution storage owner and
releases its pending claim; no further allocation or completed facts are allowed.
Resource-provider calls and callbacks occur outside the storage mutex.

| State / data | Owner and lifetime | Admission / release |
|---|---|---|
| Prepared topology and solver envelope | Immutable preparation record | Once before prepare; final record/result owner releases |
| Numerical trace capacity | Native execution storage retained by result headers and facts | Before geometric growth; final owner releases incremental leases |
| Fourier postprocessing scratch | Scoped scratch lease | Actual completed points before postprocessing; scope exit releases |
| Numerical counters | Existing execution budget | Actual work and saved points; no change to algorithms |
| Scalar/allocation policy | Caller / CLI policy | Separate ceilings; neither is silently raised or clamped |

Native/WASM/Embedded source declarations share the same Mutex storage, Sendable
contracts and entry points. This migration qualifies Native CPU execution only;
pure MOS target portability evidence is unaffected. Array/Dictionary extraction
remains the existing caller-owned value boundary, not an extension of the result
header lease. `NativeStorageAdmissionTests` owns permissive-policy, single-count,
growth-refusal and actual Fourier capacity counterexamples. Full CLI regression
and affected Analysis/NativeExecution suites verify the composed execution path.

Numerical-to-waveform conversion and SPICE output projection transport the same
opaque storage lease into the waveform header. Retained CLI waveforms, views and
ensemble members therefore retain admission after local run/facts release. Only
the lease is transported; discarded numerical payload arrays are not retained.
The reserved scalar envelope covers simultaneous conversion/projection buffers.
