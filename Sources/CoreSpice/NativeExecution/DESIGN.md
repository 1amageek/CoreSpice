# Native Prepared Simulation Execution

## Purpose and Scope

Status: implemented Native CPU capability; see supported domain below. Parent: [CoreSpice module](../DESIGN.md).
Children: [GlobalChargeKernel](GlobalChargeKernel/DESIGN.md), [PrescribedVoltageValues](PrescribedVoltageValues/DESIGN.md), [PrescribedVoltageReconstruction](PrescribedVoltageReconstruction/DESIGN.md), [PrescribedVoltageMass](PrescribedVoltageMass/DESIGN.md), [PrescribedVoltageChart](PrescribedVoltageChart/DESIGN.md), [PrescribedVoltageEvolution](PrescribedVoltageEvolution/DESIGN.md), [PrescribedVoltageFlow](PrescribedVoltageFlow/DESIGN.md). Own compilation, actual model/device binding and numerical dispatch
for a retained IO preparation; prepared analysis coverage follows the source dispatch contract below.

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
| [ValidatedTransient](../../CoreSpiceAnalysis/ValidatedTransient/DESIGN.md) | coordinates with | Conditional finite Picard numerical checks | Future same-source slab composition uses the existing chart/evolution contracts | Input-family admission, initial physical roots and continuation are separate obligations |
| [Devices](../../CoreSpiceDevices/DESIGN.md) | depends on | Actual selected model/device semantics | Physics capability | Loaded declarations are not executed model proof |
| [SDK controlled snapshots](../../../../swift-osdi/Sources/OSDIRuntime/SnapshotConstruction/DESIGN.md) | depends on | Concrete checked preparation comparison, bounded construction and immutable backing leases | Same-model source/setup capture | Arbitrary preparer conformance is not setup authority |
| [OSDI RangeExecution](../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | depends on | Actual-bound conditional capture and cleanup | Internal source-proof execution on the retained snapshot | A point, local identity or callback value supplies no circuit-flow authority |
| [PrescribedVoltageFlow](PrescribedVoltageFlow/DESIGN.md) | child | Conditional finite same-family slab composition | Uses this owner's controlled preparation and retained inputs | Its physical-family and initial-root obligations are not granted by preparation |
| [Host](../../../../Xcircuite/Sources/Xcircuite/ProfileExecution/DESIGN.md) | used by | Prepared plan, observations and output | PDK-before-execution match | Evidence is not release approval |

## Architecture

```text
PreparedSPICESimulation -> compile/bind -> PreparedNativeSPICESimulation
       -> host PDK comparison -> execute same owner -> numerical output + observations
```

## Contracts and Invariants

### Native-Only Controlled Constitutive Preparation

The explicit `prepareNativeConstitutive` child-protocol operation creates the same preparation
control before entering `checkedPrepare`, with initial ordinary floor zero. It
validates limits, environment and cancellation before control metadata admission,
and rejects OSDI inputs before compilation. The existing compiler, consuming
binder, reservation accounting, empty foreign-program backing and final floor
seal remain the single construction path. Native R/C/V proof support is decided
by actual sealed producer inspection, not by this operation's name. All later
inspection, exact algebra, captures and minor checking reuse that one owner and
remaining allowance. Ordinary public preparation still has no constitutive
backing; the OSDI snapshot preparation still requires at least one OSDI instance.

### Cold Precision Configuration Binding

Precision preparation retains its existing v5 semantic digest as `legacyBaseDigest`.
It additionally constructs immutable `NativePrecisionConfigurationFacts` from the
actual checked source owners/occurrences, effective scalar transient/convergence
settings and compiled initial rows, ordered compiled row descriptors (row, kind,
actual plan source name, unit), ordered physical row policy, actual cold
model topology/global-row mapping, program/setup identities and sizes, worker,
profiles, selected bits and options. No source parsing or worker evaluation is
performed by cold verification. Source/program bytes remain owned and checked by
their existing acquisition/artifact boundaries; the facts commit their identities.

```text
actual Native preparation -> legacy v5 base + typed replay facts
typed facts -> bounded two-pass Native framing -> facts digest
v6(base digest, facts digest) -> configuration identity
saved values -> same typed facts + base -> same Native verifier -> expected identity
```

The precision-only final domain is
`CoreSpice.native-configuration.v6.osdi-precision-binding`; the algorithm remains
precision.v3. This v6 binding applies only to actual transient analysis. OP/AC/noise
with an explicitly admitted transient precision capability retain their previous
binary64 analysis path and v5 precision-capability identity. The runtime capability
is retained, not stripped. Other ordinary identities are unchanged. The binding exposes the legacy
base, never a caller-trusted facts checksum. Verification recomputes both stages
with the same length framing, finite values, collection counts, optional tags and
explicit encoding/work/hash/storage/cancellation admission. A mismatch is typed
failure. Actual emitted phase row policy must exactly match the committed rows
before Native publishes output. Native owns its configuration facts; CLI host
live/temporary/hash/evidence ceilings remain publication provenance rather than
invented simulator settings. An externally expected artifact digest supplies
authenticity; this unkeyed configuration commitment is not a signature.

New facts metadata is admitted before construction and retained by the record;
source strings/immutable references reuse their existing owners. Cold verification
uses caller-owned immutable values and allocates only its bounded canonical
encoding after a count pass. It opens no files, acquires no libraries, and launches
no worker. Tests mutate one committed field while retaining the expected identity,
verify after actual model closure, and exercise encoding/cancellation refusal.
The internal consuming circuit augmentation first checks `compileCapacity +
factsBytes` against the same Native allocation ceiling, then reserves live storage
before constructing facts. Its immutable record copy retains that reservation and
adds the bytes to the existing aggregate execution baseline; no separate ceiling
or implicit headroom is introduced. Overflow/refusal uses the existing lifetime
failure path and preserves any cleanup retry owner.

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
source target/value. A DC evaluation projects that already admitted independent
source to its constant `v`/`i` family by removing its SIN/PULSE/PWL and timing
parameters from an invocation-local copy. It preserves `ac`, unrelated parameters
and all instance metadata; the immutable original source remains unchanged.
Preparation still rejects mixed, malformed or unsupported original source families
before any override. `NativeCircuitCompositionTests` verifies voltage/current
SIN/PULSE/PWL/constant sweeps, fresh seeded MC inner-DC samples, original OP/AC
reuse and typed invalid-original/override refusal. This is the shared native
`runSweep` contract; the checked-source IO frontend's explicit nonconstant `.dc`
refusal remains unchanged. All other devices retain their history; `.tran` passes the
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

The original dynamic source witnesses partition the fifty-case manifest explicitly.
`OSDIAnalysisNativeTests.originalACNoiseAndAnalyticTransientsValidateCompleteCandidates`
executes thirty-eight ordinary-lane cases: fifteen AC, nineteen noise (four exact
negative-PSD refusals), and four analytic transients. Its exact twelve real-model
transient IDs are assigned to
[`OSDIPrecisionFullScheduleTests`](../../../Tests/CoreSpiceOSDINativeTests/OSDIPrecisionFullScheduleTests.swift)
and the matching full CLI/C10 artifact witness. Those owners execute all original
schedules with explicit precision and unchanged physical tolerances. The old
binary64 real-model transient loop is not an additional success requirement and
is never counted as passed by delegation. Ordinary UIC/RLC, cancellation, cleanup,
fresh rerun, DC, AC and noise witnesses remain in their existing scopes. The CLI
migration separately retains the known ordinary IMG thermal precision refusal;
no model input or numerical limit is changed to make the old lane succeed.

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
lane executes the source-derived analysis cases described in Source Reexecution and
Prepared Analysis Dispatch, using the existing numerical implementations. DC source override preserves all
original instance ownership/model/branch metadata. Nodeset is passed as the actual
DC initial guess. Transient receives the prepared UIC and IC/nodeset dictionaries.

| Native admission | Contract |
|---|---|
| Preparation storage | Before cold setup, reserve the MOS retained/temporary bounds and a bounded IR/owner envelope `(devices + baseDimension) * 4096`. This byte reservation is not a logical matrix dimension. |
| Compile dimension / devices | Check the non-ground node+branch lower bound first. Classic MOS adds no private nodes. OSDI preparation independently admits its actual private rows. Check the exact completed topology against both matrix ceilings before compilation. |
| Compile / bind storage | After prepared topology is fixed, reserve a checked local-connectivity/IR/compiler envelope before compiler/binder materialization. Release preparation scratch before compilation scratch. Actual sparse factor growth is admitted separately through the execution owner. |
| Numerical topology / work | Existing TransientExecutionBudget admitted against exact compiled topology; DC uses the same shared owner across the entire point schedule |
| Execution storage | Preparation envelope retained once; requested result capacity admitted incrementally before allocation, independently of the saved-scalar ceiling |
| Numerical iterations/output | Existing pre-operation solve/Newton/work/saved-scalar admission, including DC recovery, and complete transient limit enforcement |
| Output | Only after exact complete schedule, finite validated numerical results and final cancellation check; retains its storage reservation |

The compile envelope is computed before StandardCompiler materializes topology.
Let `N` be actual prepared non-ground node slots, `B` branch slots, `D` device
slots, `L_i` each device's non-ground physical/owned/referenced node slots, and
`K_i` its owned/referenced branch slots. The triplet upper bound is
`T = N+B + sum((L_i+K_i)^2)`, plus `N^2` only for an actual optical coupling
and `2*N*U + U^2` for actual unassociated legacy branches `U`. Invalid/missing
local references may overestimate this bound; they never reduce admission.
The array extent `A` counts prepared node/branch/device slots and every local
node/branch/optical slot. Compile/bind retained capacity and its separate scratch
each reserve `256*T + 4096*A` bytes. An ownership scan first reserves
`128*(ownedBranchSlots+1)` temporary bytes before constructing its branch Set;
its lease is released before compilation scratch. Checked arithmetic and the
combined preparation/temporary peak precede every reservation. Source resource
work charges `T+A` retained elements, replacing the former cubic estimate.
These are conservative managed-capacity envelopes, not measured RSS. Pole-zero
uses the [Analysis GeneralizedSchur owner](../../CoreSpiceAnalysis/GeneralizedSchur/DESIGN.md)
for checked caller-plane, QZ workspace and output capacity. Its controlled Swift
sparse LU gain solve accounts its own factor/storage work. Native passes the same
invocation reservation and does not add the removed foreign-solver dense envelope
as a duplicate lease. The actual dense QZ path is not sparse eigensolving; its
leases coexist with admitted compile/output and embedded sparse DC storage.

The compile envelope covers prepared local connectivity and copied topology
structures. Controlled sparse workspaces and actual factor growth join execution
peak capacity through [Analysis sparse execution](../../CoreSpiceAnalysis/SparseExecution/DESIGN.md).
Execution also covers numerical trace, waveform materialization, descriptor slots
and receipts. The exact allocation formulas remain with each implementation owner.
Numerical limits and native ceilings enter the selected versioned native configuration domain
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
    -> fixed classic four-port prepared IR -> StandardCompiler
    -> take each indexed slot -> consuming bind -> private bound devices
    -> consuming execute -> completed output + copyable record
```

Native limits optionally carry explicit `mosPreparationLimits` and
`mosPreparationConditions`; both are required when MOS is present. Non-MOS circuits
need neither. Conditions must match IO ambient/nominal temperature, exact requested
analysis capability. Native MOS preparation supports only classic Levels1/2/3; official compact models enter through OSDI. No implicit condition change
or re-preparation is allowed. Aggregate execution reservations include actual native
owner receipts and topology admission before publication. Classic MOS has exactly
four ordered D/G/S/B terminals and no auxiliary nodes; it does not allocate or
reserve obsolete compact-model private slots. OSDI owns its independent dynamic
topology through the existing preparation contract. A failed stage publishes no
partial circuit or executable owner.

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
record exposes plan, conditions, limits, classic MOS receipts and OSDI preparation evidence.
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
receipts whose resolved snapshots own final values and source provenance. Generic dictionary sensitivity
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

### Borrowed Actual Native Voltage-Source Inspection

`PreparedNativeCircuit.withIndependentVoltageSources(cancellation:_:)` and the
same operation on `PreparedNativeSPICESimulation` borrow the existing executable
owner synchronously. They publish one `NativeVoltageSourceInspectionView` only
after complete validation. The view contains the actual preparation record,
complete compiled variable axis, actual native source facts, and either explicit
circuit origin or the retained SPICE source/configuration identities. The SPICE
operation delegates to the same private-device scan; it does not rebind or parse.
No swappable inspection service is needed at these concrete ownership boundaries.

```text
private prepared devices + compiled axis + original resource owner
    -> preadmit axis/fact storage -> complete source/law validation
    -> one lexical borrowed view -> release scratch
                     | copied immutable fact retains its admission + preparation
                     v
               value evidence only
```

The scan checks ordered device/IR/name association, a complete bijective variable
axis excluding ground, and every actual `BoundVoltageSource` producer. An IR
`vsource` bound to another implementation refuses inspection rather than vanishing
from the inventory. Source-local positive/negative/branch coordinates must join
that same axis and original instance. Its complete linear-law visitor must yield
exactly the signed endpoint/branch incidences and no charge terms; its structural
visitor must have no charge support. DC voltage and Waveform are copied from the
private bound producer fact, never inferred from a model name or parameter default.
The stored waveform is preserved, including finite PWL endpoint behavior and
pulse pre-delay behavior. This operation supplies no derivative, normalized Timing
family, physical rail, all-integer-cycle, root, continuation, or history authority.
An actual prepared DC-zero source remains DC zero. Future dynamic family binding
requires a separate explicit analysis identity and checked host composition.

The public view is nonescapable and has no public initializer. Facts also have only
internal construction and no decoding or executable operation. A copied fact
retains the original preparation and the shared fact-storage reservation; raw
values or public preparation records cannot instantiate an inspection. The owner
is borrowed throughout validation and callback, and no bound device is exposed.

The CoreSpice target enables the fixed Swift 6.4 `Lifetimes` and
`LifetimeDependence` features, matching the existing CoreSpiceOSDI module contract.
The nonescapable view's Span getters and lifetime-dependent internal initializer
require that compile setting. An ordinary closure alone does not express the
view-to-storage lifetime dependency. The feature settings are target-local;
clients use the imported operation with an inferred closure and inspect its Span
values without declaring a new lifetime-dependent type or initializer. A separate
consumer compile without feature flags must verify that usage; module build
success alone does not establish consumer compatibility.

With lifetime checking enabled, fixed Swift 6.4 miscompiles consumption of the
noncopyable optional device inside the native binding loop's nested selection.
The actual-import loop reproduces the compiler error with both conditional and
switch consumption. A narrow private take-and-bind helper consumes that optional
with a switch outside the loop's conditional region and returns the copyable bound
device existential. The same loop then compiles with the same optimization and
lifetime settings. The batch remains exclusively borrowed in place, each selected
device moves once into bind, and MOS/diode/OSDI/native selection order is unchanged.
A failed OSDI take or bind propagates; only an absent device selects the native
registry branch. The public nonescapable inspection view remains unchanged.

The mandatory existing CancellationToken and the preparation's synchronized
SPICESourceResourceAccounting govern every scan and publication boundary. Checked
capacity arithmetic and the existing native maximumAllocationBytes admit the
complete axis and worst-case fact array before allocation; axis scratch uses a
temporary lease and copied facts retain their live lease. Work is charged before
initialization and each finite scan/visitor operation, with no reset or new quota.
Callbacks run synchronously outside resource-owner locks. Typed failures preserve
resource and callback causes and publish no successful result; they neither close
nor consume the prepared owner. Scratch and unretained fact leases refund on all
paths. No new shared mutable state or target-specific concurrency branch is added.

| State | Storage / isolation on Native, WASM, Embedded | Access / release |
|---|---|---|
| Prepared devices and records | Existing immutable Sendable storage, exclusive consuming analyses | Inspection borrows; no mutation or close |
| Cancellation | Existing CancellationToken atomic on every target | Checked at admission, each scan and publication |
| Resource counters / leases | Existing caller-supplied synchronized accountant | Existing charge/reserve methods; reservation release owner |
| Axis / fact assembly | Lexical local arrays on every target | No concurrent access or escaping pointer; leases above |
| Armed test accountant | One Mutex<State>, no conditional storage | All state accesses use withLock; delegate calls outside lock |

`NativeVoltageSourceInspectionTests` in CoreSpiceNativeExecutionTests owns actual
R/C/V preparation, signed grounded/floating incidences, exact DC/Waveform and SPICE
identity, invalid axis/producer refusal, callback/cancellation/capacity failure,
reservation lifetime/refunds, and subsequent use of the same borrowed owner.

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
native classic MOS and OSDI analyses revalidate
physical results after package budget transport changes.

## Incremental Result Capacity Ownership

The preparation record owns both the preparation and compilation leases, charged
once at their respective allocation boundaries and retained together through
execution/output. `compileCapacity` is their sum. The compiler/solver envelope
uses exact prepared non-ground voltage rows plus branch rows, matching
CircuitTopology; the ground reference consumes no row or matrix storage.
Preparation's bounded IR byte estimate may include potential private nodes, but
never determines logical matrix admission. Preparation
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
Preparation and compilation bytes enter peak comparisons once; result capacity and active scratch
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

## Classic MOS and OSDI Model Boundary

Native MOS preparation retains only classic Levels1/2/3, with exact resolved
source, ambient/nominal temperature and requested analysis capabilities.
`NativeCircuitPreparationRecord` retains generic `mosPreparationReceipts` and
`osdiPreparationRecords`; no native compact-model diagnostics DTO or empty
placeholder array remains. The MOS source identity encoding uses
`mos-preparation.v2` after removal of the obsolete stress-policy field. Its topology
encoding contains the fixed local-node count4; no obsolete native compact-model
role/alias fields remain. Matrix admission still counts the complete circuit,
including OSDI-provided private rows, before compilation.
A resolved classic instance must supply neither owned nodes nor owned branches.
Preparation rejects either declaration with `mosBinding(.topologyMismatch)` before
creating a MOS owner or compiling; it never sanitizes ownership metadata. Failed
preparation releases every acquired reservation and permits a fresh valid prepare
using the same resource owner.
Official BULK107.2.1/CMG112.1.0/IMG103.1.0/SOI101.0.0 models use the existing
OSDI provider, actual typed preparation receipts, original physical validation
and exactly-once foreign lifetime. `NativeOSDIValueEvidence` owns its existing
independent admission and does not depend on native MOS diagnostic records.

```text
classic MOS resolved input -> classic consuming owner -> generic MOS receipt
OSDI resolved input -> OSDI consuming owner -> typed OSDI value evidence
                       -> unchanged analysis/physical gates -> completed result
```

`PreparedMOSNativeExecutionTests` owns classic L1/L2/L3 matrix admission, conditions,
lease release, source sweep, malformed supplied-ownership refusal and fresh rerun
proof. Existing OSDI adapter/Native/CLI
suites own the four external model families; deleted native BSIM and native
Sky130 fixtures are not completion evidence for that route. Changes here must
retain OSDI source identity, mixed-unit rows, paired state, cumulative quotas and
cleanup failures without introducing another model evaluator or fallback.

## Designed Diode Owner Adoption

Status: implemented on the native CPU path. Compose the [Diode owner](../../CoreSpiceDevices/Diode/DESIGN.md)
with the existing MOS preparation owner in NativeCircuitPreparer. IR carries checked
stages; prepare both families before compiling topology and consume each owner in
binding. The child contract owns feature admission, temperature identity, resource
transfer and release requirements. This composition owns complete-batch publication
and actual execution receipts; no raw registry fallback may bypass diode admission.
D5 in the [package implementation units](../../../DESIGN.md#diode-boundary-design-and-implementation-units)
owns public/API/CLI and downstream adoption checks.

D2 also adds the common source-evaluated CircuitIR environment guard before any
owner allocation. It covers temperature-dependent scalar non-MOS inputs, not just
diodes/MOS. The environment contract owns the distinction from source-free typed
runtime expressions. D5 tests preservation across compile, cloning and execution.

## D2 Circuit-wide Environment Guard

NativeCircuitPreparer checks the optional CircuitIR evaluation stamp against checked
OperatingConditions before reservations, topology preparation, compilation or
binding. This applies equally to scalar resistors and classic MOS. Classic MOS preparation
preserves the stamp. Executable owners continue to retain immutable conditions for
rebinding DC sources; no bias/sweep point changes the frozen environment.
StandardCircuitDeviceBinding enforces the same guard for direct analysis consumers.

### D3 Admission Guard

D3 originally refused resolved stages before native reservations. Checked D4
preparation now consumes those stages; raw metadata-only stages remain refused.
The [IR stage contract](../../CoreSpiceIR/DiodeInstances/DESIGN.md) owns transport.

## D4 Exact Diode Preparation

The common native owner stages one noncopyable diode owner per resolved diode,
independently from MOS owners, before compiling the complete prepared IR. Caller
supplies exact diode preparation limits and requested analyses. Batch reservations
include diode owners and their temporary/work envelopes before preparation;
consuming binding transfers executable authority without a second setup. Missing
policy, unsupported features, environment mismatch, capacity overflow and
cancellation are failures. No partial prepared circuit is returned. Receipts are
retained in preparation records and checked by each concrete analysis before its
allocation. The following 07C contract owns complete CLI/configuration receipt
encoding; preparation records alone remain non-executed evidence.

## 07C Diode Consumer and Receipt Contract

The source-native configuration digest encodes requested diode limits/capabilities
and complete prepared identity: profile/law/schema, captured declaration content and
occurrence, coefficients with origins/dispositions, raw/normalized geometry,
multiplicity, thermal input, frozen environment, effective temperature and native
implementation identity. Length-framed bounded encoding preserves source relocation
semantics and never invokes evaluation. Successful model/execution facts expose
DiodePreparationReceipt beside MOS receipt; preparation alone never produces an
executed receipt. The source-native op/DC/transient capability set must cover the actual
requested schedule; extra prepared capability never claims completed execution. Caller capacity ceilings remain explicit semantics.

Sensitivity convenience wrappers preserve the built-in registry and record-owned
conditions. Checked numeric diode perturbations retain their basis identity and
obtain fresh preparation/consume binding. The invocation reserves an additional
bounded perturbation/binding scratch envelope through NativeExecutionStorage and
holds it until all perturbations finish/fail/cancel; production preparation control
charges the existing work owner. Arbitrary raw descriptor rebinding remains refused.
Completed changed receipts retain a separate live-owned envelope derived from the actual
supplied/active schema parameter count (at most 12 model plus 5 instance roles),
model ownedByteCount, result/facts entry strides and UTF-8 identity payload extents through the returned result/facts storage owner. Scratch leases end
at invocation exit; result/facts release ends their retained claim. Twofold array/string
growth coexistence is reserved capacity, not measured RSS or allocated bytes. Admission fails
before perturbation when the combined allocation envelope exceeds the caller limit.
Fresh source MOS and diode sensitivity use the source-reexecution binding and
retained ledger described below; source-free MOS dictionary rebinding remains refused. Tests exercise API configuration differences, execution,
receipts, retained-input rerun, numerical typed perturbations and bounded failure.

## S3 OSDI Native DC Composition

Status: implemented and behaviorally verified on Native macOS arm64 DC. NativeExecution
composes the [OSDI adapter](../../CoreSpiceOSDI/DESIGN.md) through the original
`SPICENativeSimulation` and `NativeCircuitPreparer` APIs. An async overload accepts
`SPICEOSDIRuntimeInputs`: a fresh-image library provider, exact load/evaluation
limits, aggregate instance/adapter bounds and explicit temperature/power tolerances.
The synchronous overload rejects OSDI input lacking that runtime contract.

```text
retained typed source input + OSDI runtime inputs
  -> async exact-artifact acquisition and setup
  -> existing synchronous MOS/diode preparation and sparse compilation
  -> consuming per-instance OSDI binding
  -> existing DCAnalysis + SparseLU
  -> independent raw physical residual validation
  -> explicit model/image close
  -> completed event, receipts and waveform
```

The initial OSDI schedule is operating point only. OSDI circuits may contain the
existing static resistor and independent voltage/current-source devices; another
legacy device in that circuit is explicitly unsupported until it supplies an
independent physical equation contract. Non-OSDI schedules retain their existing
capabilities. OSDI stages survive every native IR clone without legacy registry
fallback. Exact prepared internal voltage/current/thermal coordinates contribute
to checked matrix admission before compilation.

| Obligation | Owner / evidence |
|---|---|
| Exact model, typed parameter scope, previous state and Kelvin identity | Retained resolved input and complete prepared/executed receipt |
| Update and equation units | Explicit DC row policy: V/A, A/V and K/W |
| Physical acceptance | Raw OSDI residual projected into global rows plus device-owned original R/V/I equations; absolute residual bounds never use Newton RHS scale |
| Foreign lifetime | Prepared/bound execution owner; close evaluator buffers before its library, before completed publication |
| Failed cleanup | Preserve original failure, cleanup failure and retryable lifetime owner; no completed result |
| Fresh rerun | Retain full runtime input and source preparation; obtain independent images and setup again |
| Capacity and cancellation | Existing native owner plus adapter aggregate bounds; refuse before numerical publication |

`Tests/CoreSpiceOSDINativeTests` owns original API execution against the independent
DC manifest, raw residual acceptance/refusal, exact identity, cancellation, capacity,
cleanup, fresh rerun and unchanged non-OSDI execution. Preparation evidence alone
is never reported as executed OSDI evidence.

The explicit local platform adapter `SPICEOSDILocalLibraryProvider` retains an
immutable root identity/directory, digester, exact-reference catalog of bounded
read intents and absolute staging directory. Its initializer rejects duplicate
identities, another root, nonlocal availability or nonread intent. Each load opens
a fresh `ArtifactRootCapability`, invokes the existing S2 loader with a fresh
private image and awaits root close/drain before returning that independently
staged library. This preserves fresh reruns from retained output without retaining
an open root descriptor. Failures retain load and cleanup diagnostics. Native
execution owns each independently acquired image. No path enters canonical model
identity and no cache shares mutable model storage between instances.

Physical residual comparisons use the explicit equation absolute tolerance.
Compensated sums retain small terms during circuit assembly. Absolute physical
contribution sums may support diagnostics only; neither those sums nor the OSDI
Jacobian-times-state and Newton right-hand side enlarge the acceptance tolerance.

The native physical validator consumes only the generic device-owned
`DCPhysicalResidualContributing` boundary. It never reconstructs even linear
resistor current from matrix coefficients: the device computes the terminal
voltage difference before applying its actual prepared conductance. OSDI circuits
reject devices lacking this direct original-equation capability before execution.

Configured numerical regularization remains separate from original physical
equations. OSDI qualification fixtures explicitly select `gmin = 0`; native
execution never silently changes caller gmin or enlarges physical tolerances.
If numerical regularization leaves an original-equation residual outside the
absolute bound, execution fails before completed output.

### S3 C1 Behavioral Evidence

The exact Swift 6.4.0 Native test target `CoreSpiceOSDINativeTests` executes the
original source/API path for the immutable four-family qualification manifest:
43 cases, 41 completed solutions, two expected singular/nonconvergent failures,
and every one of 310 returned coordinates independently re-evaluated by the direct
C ABI oracle. BULK 107.2.1, CMG 112.1.0, IMG 103.1.0 and SOI 4.7.0 cover loaded,
reverse, hot, private series, floating/body-contact and K/W thermal coordinates.
This is DC circuit integration evidence for those exact fixtures and artifacts;
it does not qualify AC, transient, noise or foundry process accuracy.

The same target checks fresh retained-input rerun and configuration identity,
missing runtime inputs, compiler refusal of resolved stages, wrong descriptor,
pre-cancellation, setup-created matrix rows, aggregate adapter capacity, direct
native/source schedule refusal, failed cleanup without completed output, explicit
cleanup retry and closed image state. Direct R/V/I tests verify large common-mode
resistor arithmetic, actual admitted source DC behavior and invalid state bounds.
The ordinary prepared-source divider remains executable and rerunnable. Existing
native CPU and CLI consumer suites own the broader cumulative regression check.

## S4 Whole-Analysis OSDI Execution

### Fresh Local Precision Worker Acquisition

`SPICEOSDILocalArtifactSource` owns local acquisition policy through the existing
`ArtifactAccessing` protocol. Its value retains only root configuration and a
digester; each read/local/matching-root open creates a fresh root capability.
The returned actor owns that root and its bounded read session. Terminal reads,
explicit close, read errors and cancellation converge on one stable termination
task: close and wait for the session, then close and wait for the root. Waiting
for root drain first would deadlock and is prohibited. Concurrent close/wait
shares the same result. Cleanup completes independently of caller cancellation;
read, session-close and root-close causes remain explicit under the fixed
Foundation error contract. No descriptor or root capability survives between
opens or retained-input reruns, and asynchronous deinitialization is not a
cleanup mechanism. Focused Native tests exercise actual local bytes, repeated
acquisition, identity/budget/cancellation refusals, concurrent termination and
descriptor release.

Native composition admits OP, AC, transient and noise through existing analysis APIs.
The immutable preparation record retains exact acquisition inputs; each rerun performs fresh setup.
Original device equations own DC/transient residual terms; Native combines them using compiled
V/A, A/V and K/W row policies without matrix/RHS-derived tolerance enlargement.

```text
prepared owner -> physical OP validation -> complete analysis -> transient session end
 -> completion finalizer closes model buffers then library -> completed event/result
```

Pure operating-point validation never closes model storage. The outer analysis completion
finalizer owns successful close; failure cleanup preserves primary/secondary causes and retry
ownership. Actual nested OP results, transient accepted-step audits, complete noise results and
phase facts survive Native output and saved CLI projection. Noise observable columns are not MNA
rows. Frequency analyses inject the same bounded result-storage owner as transient.

Native tests compare complete AC/trajectory/noise candidates for all four pinned families with
the independent S4 capture manifest, including explicit invalid-PSD failures. Mixed RLCVI uses
private admitted device coefficients and actual source waveform time, with capacitor current
updated only at accepted steps. Existing nil-policy legacy behavior remains supported.

Physical validation allocates one compensated-sum workspace per consumed run and reuses it
for OP and transient candidates. A Mutex protects exclusive workspace take/return; contributor
calls occur after taking the workspace and outside the lock. Concurrent validation fails busy.
All Native storage, isolation and read/mutation entry points use this same declaration; this
host composition makes no WASM/Embedded execution qualification claim.

### Compensated Transient Wrapper Propagation

The existing `TransientAnalysis.run(circuit:...)` preserves an explicitly supplied
`physicalResidualEncloser` when composing its lower analysis. A requested precision
lane must return a matching low trace and complete accepted-step audit; Native checks
every saved normalized pair and the exact represented interval before returning a
`NativeCircuitRun`. It retains the lower result and its existing storage lease without
projecting or reconstructing either component. Ordinary calls retain their nil low
trace and existing result behavior.

```text
explicit enclosing provider -> prepared Native wrapper -> paired lower analysis
  -> full high/low trace + exact interval audit -> same retained Native result
```

This forwarding contract does not supply OSDI model precision capability. Until the
complete OSDI precision composition replaces its legacy residual evaluator, combining
that mandatory legacy provider with an explicit encloser receives the lower typed
incompatible-precision refusal. An encloser is never silently dropped to execute the
ordinary lane. Native OSDI precision composition and its model-owned proof remain a
separate adoption step.

`NativeCompensatedTransientTests` exercises an actual prepared RLCVI circuit with a
complete enclosing provider, sub-ULP current-driven capacitor updates, exact high/low
and interval preservation, completion after device session end, result-lease release,
and the ordinary compatible path. Lower arithmetic and interval certification remain
owned by the [compensated transient design](../../CoreSpiceAnalysis/CompensatedTransient/DESIGN.md).

### Automatic Model-Owned Precision Composition

`SPICEOSDIRuntimeInputs.transientPrecision` is an explicit optional
`OSDITransientPrecisionInputs`; nil preserves ordinary execution. Preparation
passes it to the adapter, reserves each worker's maximum mapping and arena in
the aggregate Native budget, and includes adapter-owned program/setup storage
in the adapter budget. Each actual bound model supplies an immutable precision
receipt joined by instance and exact image identity into
`NativeOSDIPreparationRecord.transientPrecision`. A precision request requires
every OSDI instance to have the matching receipt and every circuit contributor
to implement the paired original-equation boundary before execution begins.

```text
explicit precision policy -> same model setup + exact worker/program receipts
 -> complete paired contributor set -> lower enclosing Newton/BE/TR gate
 -> original per-row tolerances -> complete high/low result and exact intervals
 -> configuration identity + immutable receipts -> fresh retained-input rerun
```

The Native enclosing provider forwards all device-owned signed centers/radii,
validates row/radius bounds and cancellation, and leaves rigorous accumulation
and the fresh final physical gate to Analysis. Its final validation hook applies
only the caller's additional rejection constraint: it does not reevaluate or
replace that gate. The ordinary OP validator and outer completion finalizer
remain active. The legacy transient equation evaluator is not simultaneously
selected. An additional caller-supplied complete encloser conflicts with this
automatic complete-circuit provider and is explicitly refused.

Preparation identity includes the exact worker, program/setup and declared
semantic/numeric profile digests, precision bits and every numeric resource
limit through the [Native-owned precision configuration](#native-owned-precision-configuration).
The algorithm identity is `CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3`.
Full receipts survive owner closure and are not execution authority. Ordinary OP/AC/noise calculations retain their declared binary64
representation even when preparation also admits the transient precision lane.
Actual four-family Native/CLI execution, exact saved/reloaded paired evidence,
independent replay and fresh rerun are required before this composition is
qualified; declarations alone do not establish that evidence.

Completed transient `NativeCircuitExecutionFacts.equationPolicy` retains the
actual selected immutable row policies. Artifact/replay consumers serialize
those variable/equation tolerances and kinds instead of reconstructing them
from units or defaults. Exact source captures and effective analysis settings
remain the replay input authority; cold model receipts do not replace the
original circuit or source waveforms.

### Native State LTE and Algebraic Source Currents

LTE controls the admitted state coordinates. Equation absolute tolerances constrain original
discrete physical residuals; they do not certify the continuous-time error of every derived
output. Complete current/voltage/thermal trajectories and step-refinement comparisons are
separate qualification evidence. No interval or all-history guarantee is inferred from either.

The automatic Native OSDI profile uses an empty LTE set only when the entire circuit consists
of actual R/V/I devices and OSDI devices whose every raw node, including grounded and collapsed
nodes, advertises no reactive residual offset. Otherwise it controls all canonical coordinates
except an actual independent BoundVoltageSource's uniquely owned, structurally unreferenced
branch current. This is a reaction current, not a storage coordinate. Inductor currents, OSDI
private flow variables, thermal variables, and raw time/native-state-dependent Q remain intact.

```text
whole admitted circuit has structural Q absence -> empty state LTE set
otherwise known RLCVI + OSDI -> all coordinates minus proven ideal-source reaction currents
unknown device / missing ownership / referenced source branch -> complete coordinate set
```

The nonreference proof uses the admitted device boundary: R/C/L coefficients are prepared
numeric values, capacitor storage reads terminal potentials, inductor storage reads only its
own branch, and independent sources have time-only waveforms. OSDI external terminals accept
potential coordinates only; private flow branches receive fresh exclusive IDs. Behavioral,
current-controlled, mutual and unclassified devices are outside this Native profile. Compiler
and binding enforce exclusive branch ownership. Native additionally refuses to exclude a
source branch if another instance claims or declares a reference to that branch, or its identity is unavailable.

An explicit complete set remains valid. An explicit automatically derived set also remains
valid; other partial selections are refused. Every Newton equation, direct physical residual,
accepted history and returned coordinate continues to use the complete system. A nil request
selects this documented automatic profile without discarding explicit caller choice.

Native tests inspect real no-Q/nonlinear-Q metadata, source branch ownership and OSDI private
flow/thermal retention; adding an inductor preserves its storage current, and conflicting
branch ownership fails closed. Full independent trajectory and refinement comparisons own
derived-output accuracy evidence.

### Direct Transient Newton Defect

The Native transient physical validator also provides original residual terms to the generic
Newton solver through TransientPhysicalResidualEvaluating. The caller's prior acceptance
validator remains a final-candidate constraint and is never interpreted as an equation source.
Every Newton evaluation uses the same immutable accepted device history and integration
context. The solver corrects with J delta = -Fphysical and accepts only the original direct
residual under unchanged row tolerances, avoiding loss of small F in a large Jx-minus-F RHS.
Native contributes actual RLCVI and OSDI terms; it introduces no solver or model fallback.

The paired BULK transient diagnostic demonstrated Jx-rhs = -3.18e-15 while original gate
residual was 1.49e-12 at the same candidate. A direct defect correction reduced that row to
8.18e-15 and every row below the original 1e-12 limit. Generic numerical tests and the full
independent Native schedule replay own completion evidence for this corrected path.

### Distinct Adjacent-Time Precision Failure

Qualification profiles explicitly choose their intended final PWL time. Native execution
never coalesces distinct requested event times or drops a requested terminal interval.
A requested stop at the final knot's next representable Double remains a separate numerical
problem; if the original physical tolerance cannot be met, execution fails before completed
output and closes model buffers/libraries. The adjacent-stop native regression preserves this
failure while the normal source profile uses its explicitly selected PWL endpoint.


### Native-Owned Precision Configuration

Actual transient precision preparation publishes a v6 identity. Native owns both
`NativePrecisionConfigurationFacts` and bounded canonical encoding through
`NativePrecisionConfigurationVerification`. The previous complete v5 digest is
retained as `NativePrecisionConfigurationBinding.legacyBaseDigest`; it is a base
commitment, not the final precision identity. Native hashes actual replay facts
under `CoreSpice.native-precision-replay-facts.v1`, then binds that digest and the
legacy base under `CoreSpice.native-configuration.v6.osdi-precision-binding`.

Facts cover the exact source input, captures and occurrences, effective settings,
ordered compiled rows, actual equation policies, actual model topology/parameters
and global mappings, program/setup/worker identities, numeric/semantic profiles,
precision bits, resource limits and solver/algorithm identity. The encoder is the
single framing owner. CLI converts its checked DTO into these values and calls
the verifier; independent qualification implements its own checker. Verification
performs no model loading, evaluation or source parsing. It enforces injected
encoding/work/hash/storage bounds and retains causes. The actual phase policy
must match the committed policy. Nontransient preparation keeps its previous
identity and binary64 numerical representation even when precision capability is
present. External expected artifact identity remains the authenticity boundary.

`NativePrecisionConfigurationTests` owns mutation, bounded storage/lifetime,
nontransient compatibility and cold verification tests. The completed full
qualification independently admits 24 saved/reloaded artifacts and checks all
3400 accepted steps at 512 bits, with maximum normalized original residual upper
`1.1169194501513867e-6`. Its local aggregate receipt SHA-256 is
`8e20c87c0fccc45c5629a8aa5755bedbb904cddbf1cdd793cad13f4f73e7e2f6`.
This is finite-fixture circuit evidence, not interval/all-history certification.

### Precision Transport Measurement

The local r3 measurement reuses the qualified exact program/setup and normalized
vectors at 256 bits with a 64 MiB worker arena. Each family uses a fresh worker,
then a separate first request and 100 contiguous requests. The unchanged helper
packs inputs, wakes the worker, reads the probe and materializes output lists
inside the measured request interval; bit equality against all eight baseline
slabs is checked outside timing. Cold timing begins with already-staged immutable
program/setup and includes helper construction, slabs, spawn and ready; it does
not measure filesystem-cache behavior or complete Native circuit throughput.

| Model | Create to ready (ms) | First request (ms) | Mean of 100 requests (ms) |
|---|---:|---:|---:|
| BULK | 36.152 | 7.901 | 7.245 |
| CMG | 36.143 | 7.196 | 6.866 |
| IMG | 19.542 | 10.157 | 11.841 |
| SOI | 29.389 | 9.276 | 5.658 |

All 404 results match the original complete baseline bits. Every measured request
has zero child OS malloc/calloc/realloc/free calls and requested bytes. Private
arena allocation/copy activity is not claimed to be zero. The four input memcpy
operations have structural payload budgets 224/256/288/448 bytes per request;
borrowed output slab sizes are 5440/5440/2080/3808 bytes. These are structural
budgets, not measured total-copy counters. The local receipt SHA-256 is
`738e754dfb0e90b6440c3a51b40a206a5db4b9fca4d36d779d40f6155191c472`.

### Durable compensated DC output

`SPICENativeSimulationOutput` retains the complete operating point or `dcSweepResult`.
`SPICENativeStoredDCResult` version 1 is the durable DC value contract: ordered
node/branch identities, source coordinates for sweeps, per-point iterations,
representation (`binary64` or `compensated`), and exact binary64 high/low bit patterns.
Decode validates row bijection, dimensions, finite normalized pairs, and analysis /
coordinate consistency through the same validation used for construction. Restoring
a point preserves both components. This is numerical state, not an OSDI transient
precision receipt or authorization to resume executable device state.

```text
DCResult / SweepResult<DCResult> -> stored DC bits -> JSON -> validated DCResult
                               -> WaveformData -> binary64 display projection
```

Native DC admission reserves low-component arrays before numerical execution.
Each native-owned stored-value construction and each `result(at:)` restoration
admits its own row/map and high/low buffer capacity before allocating it. The
returned immutable value retains that independent lease until its final copy is
released. Failed materialization admission allocates no output and preserves the
completed numerical owner; releasing an earlier materialization allows a retry.
Decoded offline values remain caller-owned, outside the native invocation quota. CLI serialization additionally reserves temporary encode/string/strict-reload
coexistence for the new DC payload. Its checked upper bound uses 32 bytes per
UInt64 token (at most 20 decimal digits plus separators/indentation), 256 bytes per
row/point metadata, six bytes per escaped UTF-8 source-name byte, and four
coexisting generations. Existing outer envelope metadata retains its existing owner. The numerical saved-scalar ceiling counts high coordinates and additional low
components, as owned by Analysis; byte admission separately bounds storage.
Tests own bit-exact operating-point/sweep reload, malformed low/count/row refusal,
and the original one-microohm compensated circuit through native and CLI paths.

All native schedules requiring DC additionally admit a shared working-state upper
bound of eight row-sized Double buffers and their headers, including
embedded operating points for AC, noise, transfer function, pole-zero and
sensitivity. This fixed peak envelope is separate from per-saved-point DC low
payloads and independently leased materializations and is admitted once, without changing caller ceilings. It is a
conservative capacity reservation, not measured allocation. Binary64-only schedules
may use less than the admitted upper bound. Selection additionally admits one
`any DCPhysicalResidualEnclosureContributing` existential per instance using its
actual `MemoryLayout` stride, plus its array header. Optional and final
`DCEquationRowPolicy` row tables coexist during selection; both payloads and
headers are admitted. Row-bijection validation additionally admits a conservative
four-Int-slot Set envelope per row and the Set header. These are distinct from
instance execution-fact bytes, so device population much larger than matrix
dimension cannot consume an unrelated fact reservation as implicit capacity.

The non-OSDI prepared analysis implementation is identified as
`CoreSpice.NativeCPU.source-analyses.v3`, with configuration domain
`CoreSpice.native-configuration.v3.diode`. OSDI algorithm/domain identities retain
their existing binary64 and independently qualified transient contracts.

Materialization accounting adds no target branch or new mutable owner. The same
NativeExecutionStorage `Mutex<State>` protects claim, rollback and release;
provider reservation and lease destruction callbacks run outside that lock.
A MaterializationLease holds immutable owner/reservation references, and the last
reservation copy performs exactly one refund.

| Execution surface | Storage / isolation | Read and mutation | Final release | Evidence |
|---|---|---|---|---|
| Native host | Existing `Mutex<State>` | Existing claim plus rollback/refund through `withLock` | Last reservation copy | Retained-copy quota/refund/retry and simultaneous materialization/release test |
| WASM / Embedded | Same shared Mutex storage and Sendable declarations | No alternate raw-state implementation | Same reservation owner; runtime unverified | No Native result evidence generalized |

## Source Reexecution and Prepared Analysis Dispatch

Prepared TF/PZ/sensitivity/Fourier dispatch consumes the same source-derived
effective configuration as OP/DC/transient/AC/noise. Typed numerical results are
retained beside their actual waveform and execution statistics. Fourier owns its
supporting transient path; PZ records whether poles, zeros, or both were requested.
For source sensitivity the binding owner retains captured source and policies,
creates a new source overlay/snapshot and native preparation for each perturbation,
and records every completed reexecution with its source/configuration identity
and actual MOS topology. Fresh compilation may change auxiliary topology; child
analyses execute the returned plan and share the invocation's cumulative budget.

```text
source selection -> prepared configuration -> consuming native analysis
                      sensitivity -> source scalar overlay -> fresh frontend
                                  -> fresh native topology -> child solve
                                  -> retained reexecution provenance
```

Source binding state is a bounded completed-record ledger protected by one Mutex
on every target. Resource/cancellation callbacks and compilation run outside the
critical section. Each returned PreparedCircuit retains its source and native
preparation owner through the awaited solve; published native phase facts retain
the completed source ledger after the binding owner leaves scope.

| Shared state | Native / WASM / Embedded declaration | Read / mutation entry | Lifetime | Runtime evidence scope |
|---|---|---|---|---|
| Source reexecution count, active count, completion records, frozen state | One unconditional `Mutex<State>` | `sensitivityParameters` borrows immutable input; `bind` and `finishReexecutions` access ledger only under `withLock` | Binding owner; frozen ledger retains metadata reservation and captured input | Native macOS; WASM/Embedded are not claimed by this host execution component |

Source parameter inventory and patches use the lower frontend's supplied scalar
coordinates, including raw source geometry units and parameter role. Selector,
derived and inherited values do not become independent numeric coordinates. The
completed ledger reserves the retained configuration/provenance envelope separately
from native topology storage; it does not hold every case's full frontend arena.
The child solve retains the full fresh source owner until that solve exits.

Fresh binding recognizes cancellation from the actual captured-source/native error
cause, including resource-accountant cancellation wrapped by preparation. It emits
Analysis cancellation before the generic analysis terminal event. A cancelled token
alone never replaces an unrelated failure. OSDI cleanup values remain unchanged,
including their original primary cause and complete retry authority.

## OSDI Composite Analysis Schedules

Native owns the OSDI composition of DC sweeps, TF, finite affine PZ and Fourier;
the Analysis module continues to own each numerical algorithm. All these
schedules use the same exact prepared OSDI topology, original-equation
contributors and mixed electrical/flow/thermal row policy as the existing OP,
AC, transient and noise lanes.

```text
exact prepared owners -> bounded schedule admission
 -> DC child policy + original-equation acceptance
 -> complete sweep / TF / PZ / configured transient + Fourier integration
 -> final owner close -> completed schedule
```

DC sweep replaces only the selected independent source. Each point builds its
physical validator from that point's actual devices, so a changed source cannot
be validated against the previous source value. Child DC solves do not close
owners; the entire sweep finalizes once after its last callback. TF and PZ inject
the same row policy and validator into their internal OP, and finalize after all
small-signal solves or pencils are complete. PZ additionally requires every
device's explicit affine realization contract.

`NativeCircuitExecution.configuredTransientAnalysis` is the sole owner of Native
OSDI transient composition. Ordinary transient and Fourier reuse it without
copying evaluation, integration or physical equations. Fourier supplies that
configured analysis through `FourierAnalysis.preparedTransientAnalysis` and
defers the OSDI close to its outer completion finalizer. The child preserves
original-residual validation, structural LTE coordinates, the precision encloser,
accepted high/low traces and native trial/accepted state semantics. Fourier
postprocessing retains the complete transient result; it never substitutes a
shortened or ordinary trace for an explicitly selected precision schedule.
Source preparation owns binding the Fourier transient configuration to the same
precision replay facts as a direct transient request.

Each wrapper admits physical-validation storage before creating contributors or
row policies. Failure/cancellation closes the exact prepared lifetime through the
existing typed cleanup path. A successful outer finalizer closes native models
before reporting schedule completion; cleanup failure remains a failed result
with retained retry authority.

Multi-circuit failure cleanup snapshots pending records before leaving the source
binding's isolation boundary. `failure(_:closing: [NativeCircuitPreparationRecord])`
merges their lifetimes with any incoming preparation/execution cleanup authority,
including a failed preparation that never published a record. It deduplicates
execution owners by identity, attempts every close outside locks, and retains the
unchanged primary error plus every typed close failure in one retryable cleanup
value. Reservation copies retain their existing exactly-once refund owner and
never charge capacity a second time. Retry therefore covers the complete failed
schedule, even when several foreign images remain busy independently.

`OSDICompositeAnalysisNativeTests` and `OSDICompositeAnalysisCLITests` exercise
the public API and source/CLI routes with exact captured BULK/CMG/IMG/SOI model
artifacts. Existing full precision transient tests remain the owner of the
unchanged long high/low schedules; composite tests verify their shared adapter
selection and the additional schedule lifecycle and numerical relations.

### Successful Sensitivity Children and OSDI Reexecution

The source binding ledger is private preparation evidence until a successful
SensitivityResult/ACSensitivityResult is joined in order. Every child must match
its device/role-qualified parameter, raw nominal/replacement, exact compensated
increment, source override or OSDI typed assignment, and fresh output-node mapping.
Only then does a SPICENativeSourceReexecutionCompletion expose its actual op/ac
phase and selected-output observation. Baseline op and derived sens/sens-ac are
separate completed phases. Fresh model origins are copied from each child's own
compiled snapshot; baseline snapshot identities cannot resolve a child model.

OSDI scalar inventory uses only explicitly supplied real assignments whose exact
prepared metadata admits their role/name. Async source binding rebuilds the typed
model/instance assignment arrays, preserving artifact/descriptor/provider policies
and initial previous-state input, then loads and prepares isolated owners. Actual
baseline/child DC and AC receive the record-derived mixed-unit equation policy,
original physical validator and final completion cleanup. All pending owners are
closed on failure, preserving aggregate retry authority when cleanup fails.

Prepared Fourier selects its supporting transient configuration for precision
binding and final physical validation; no binary64 fallback substitutes for a
requested paired model-precision path.

Closed OSDI child evidence retains the IR/setup, compiler and immutable OSDI
metadata value admissions, not the foreign runtime workspace ceiling. A separate active preparation retains
executable foreign owners until the actual numerical completion finalizer closes
them; that resource finalizer releases the active owner outside the ledger lock.
This resource lifecycle notification does not publish child execution evidence.
Only the final successful result/ledger join publishes completed observations.
The common baseline remains retained once; subsequent child setup does not retain
all earlier foreign workspace ceilings.

The composite Native regression suite also runs ordinary DC and AC source sensitivity
for all four pinned model families. It checks each supplied real assignment against
the fresh typed child receipt, recomputes derivatives from physical observations,
and independently repeats one exact child patch per family and physical analysis.
Every tracked baseline/child image must close after the schedule.

## Dual Original Transient Gates

OSDI schedules retain the existing companion gate and additionally enforce the
canonical accepted-step equation on all electrical/flow/thermal rows. The global
static F buffer includes every admitted native primitive and source. Trial static
F and unadjusted constitutive increments come from explicit device decomposition
capabilities; no matrix/RHS reconstruction or missing-provider fallback is allowed.
For differential capacitance the device supplies its distinct constitutive increment
and explicit differential-history correction; neither is relabeled conservative Q.

A Mutex checkout owner retains fixed accepted-F, trial-F and increment buffers.
The first final candidate lazily captures initial static F from the exact Analysis
previousVariables/paired-history view at the explicit lifecycle initial time zero.
OSDI returns F cached by actual TRAN|IC|STATIC begin; native sources use their
time-zero waveform at that same initial vector. TR cannot use an uninitialized
baseline. No previously accepted F is recomputed. Current trial terms and all row
bounds validate before device commit. The existing onStepAccepted hook promotes
trial F only after every device commit succeeds, then invokes the caller callback
outside the lock. Rejection, cancellation and failed commit do not promote F.
A completion check rejects a missing/mismatched promotion before closing owners.

The ordinary lane sums binary64 model terms with checked compensated accumulation;
it does not obtain a precise model by conversion. The paired lane propagates model
and arithmetic enclosures throughout both gates. The unchanged original absolute
row tolerance gates each canonical bound. Fixed workspace and provider arrays are
admitted by dimension/device count; every extra evaluation/vector pass charges the
same cumulative numerical budget and preserves cancellation/library ownership.
Verification compares signed canonical and companion rows against the unchanged
independent oracle, including a candidate that passes one gate but fails the other,
rollback, exact prior source context, and full precision profiles.

| Canonical history target | Storage/isolation | Read/mutation | Release |
|---|---|---|---|
| Native | One `Mutex<Buffers?>` checkout owner | `validate`, `promote`, `validateCompletion`; external device/user callbacks unlocked | Analysis closure/finalizer scope |
| Ordinary WASM | Same declaration and synchronization; native OSDI acquisition unavailable | No alternate raw history branch | No native capability claim |
| Embedded WASM | Same declaration and synchronization; native OSDI acquisition unavailable | No alternate raw history branch | No native capability claim |

The added current/initial evaluation and vector passes charge the exact shared
`TransientExecutionBudget` used by the analysis, including Fourier's prepared child.
Capacity includes three dimension-sized enclosure payloads, one selected decomposition
existential array, and the history owner's explicit logical state/header footprint.
No observation, byte budget, tolerance or worker precision ceiling is raised.


The two original transient gates share only complete same-trial source facts through
[the OSDI execution owner](../../CoreSpiceOSDI/DCExecution/DESIGN.md#same-trial-source-facts-for-both-original-gates).
Native charges the owner's fixed source-record initialization once and its
comparison/copy/arithmetic work bound before each companion and canonical contribution through the existing cumulative transient
budget, including Newton companion queries. These charges remain on mismatches and
failures; no independent allowance is created. Owner records do not replace either
gate, change tolerance, or eliminate candidate-bound/accepted-commit evaluations.


### Numerical Result Storage and Closed Foreign Owners

`NativeExecutionStorage` retains the preparation's value evidence (IR/setup,
compiler and immutable OSDI metadata leases), rather than its foreign execution
lifetime/workspace reservation.
The actual consuming analysis record, devices and completion finalizer retain the
full foreign owner throughout execution. A cleanup failure retains the complete
lifetime and reservations until the caller closes/releases its retry authority.
Stored DC bits and subsequent JSON/CSV materialization therefore preserve numerical
capacity without retaining one closed foreign workspace per completed family case.

The original full preparation `compileCapacity` remains an immutable allocation
floor for every result and scratch admission; releasing an executable owner never
weakens the native allocation ceiling. The floor scalar and the value-receipt
backing coexistence (three receipts for OSDI) are admitted before copying value evidence. Result accounting
uses the same unconditional `Mutex<State>` on every supported target; no callback
or external resource admission runs under its lock.

`NativeResultStorageLifetimeTests` owns direct stored-sweep retention/materialization,
next-case admission, unchanged original-floor refusal, active cancellation cleanup,
and busy foreign cleanup/retry authority. The source condition family tests verify
that these local lifetime guarantees compose with four actual OSDI model families.

### Completed Source Provenance Storage

A source child ledger retains the exact effective configuration and immutable
[frontend provenance](../../CoreSpiceLowering/Frontend/DESIGN.md#immutable-evaluation-provenance-capacity),
not the consumed evaluator's full `retainedBytes` statistic. Its existing record
array admission owns inline headers; the per-record lease admits configuration
capacity plus the provenance's checked actual buffer/text payload before publishing
the value. Measurement work and cancellation use the same source accountant.

Active baseline/child prepared inputs continue to retain their original frontend
and transformation leases. Actual foreign lifetimes remain with the consuming
prepared circuit/devices/finalizer and cleanup failure; completed value evidence
retains the existing IR/compiler leases. This separation removes no live owner's
reservation and changes no resource ceiling or model/source facts.
`ImmutableProvenanceStorageTests` verifies the exact payload independently of
session diagnostic policy. Existing result-storage lifetime tests retain their
ownership/refusal/cancellation/release coverage. The four-family ordinary
source-sensitivity CLI test verifies this correction under unchanged default
invocation limits, including the previously refused ledger/compiler admissions.

### Immutable OSDI Value Evidence Admission

A prepared OSDI receipt keeps resolved-parameter arrays and each parameter's names,
description, units and possible string value independently of the foreign model.
Topology text/arrays, raw-row maps, resolved source assignments/previous state and
optional cold precision program/setup bytes also remain in `valueEvidence()`.
Circuit-row/instance IR and compiler envelopes alone do not bound this payload.

`NativeOSDIValueEvidence` checks actual array capacities and UTF-8 payload from the
prepared records, including inline record headers and the fixed reservation-array
construction/coexistence envelope. It uses the original source accountant before
each header/array/fact/text admission and checks cancellation between records and
facts. It materializes no payload. Shared parameter-name/topology backing may be
conservatively counted more than once; no allocation identity introspection or
metadata-policy ceiling substitutes for the actual field accounting.

The preparer creates one metadata lease before publishing the prepared record,
while the original foreign admission still covers setup. This brief conservative
double admission copies no metadata and keeps the original allocation floor plus
the new metadata capacity within the same immutable native limit. OSDI reservation
order is IR/setup, compiler, immutable metadata, foreign runtime, later validation.
Value evidence retains the first three leases; subsequent conversions reuse the
same metadata release owner without a new reservation. Non-OSDI order and its
existing execution-header boundary remain unchanged. NativeStorage and source
ledger callers separately admit their three-receipt value-array backing before
copying. Cleanup failure retains all original reservations; successful close
releases the foreign runtime ceiling when its full record/device owners expire.

`NativeResultStorageLifetimeTests` verifies actual CMG parameter metadata exceeds
the former IR/compiler-only capacity, survives foreign close under its exact shared
lease, repeated evidence conversion does not reserve again, subsequent preparation
fits the unchanged tight ceiling, and all leases refund at final release. Its
existing cancellation, busy cleanup, JSON/CSV and original-floor refusal cases
remain required. `NativeStorageAdmissionTests` retains exact non-OSDI boundaries.

### Fixed-bias voltage-controlled network execution

The explicit IO network selection dispatches `NetworkParameterAnalysis` through
the existing consumed prepared circuit. It admits DC/AC model capabilities and
uses the same original-equation DC validator, equation policy, OSDI completion
finalizer, cancellation token and invocation numerical owner as AC. One actual
DC solution precedes every independent voltage-basis column at each positive
frequency. Non-port independent AC excitations are suppressed while retaining
the original matrix and DC source values. Port current is positive into the DUT
and therefore the negative of its source's oriented branch current.

Only a completed full frequency/port schedule produces `[op, network]` facts and
a typed `NetworkParameterResult`. The output retains actual port bindings, bias,
full S/Y matrices, conditional Z availability, sampled two-port stability facts
and backward residuals. Open admittance can succeed with undefined Z; a singular
voltage-clamp system or S transform is a typed refusal, not a fabricated matrix.
No reciprocity/passivity assumption discards active or nonreciprocal values.
Pointwise two-port criteria do not assert internal-mode or continuous-band stability.

RF result/presentation metadata capacity is added to the existing Native retained
reservation with checked arithmetic; lower-owned scratch remains lower-owned.
No independent budget reset or duplicate physical model preparation is introduced.
Failure/cancellation closes the existing foreign owner and returns no partial
completed network result. The typed result retains the same result-storage lease.


## Actual-Owned Constitutive Snapshot Preparation

This lane connects the qualified CoreOSDI controlled snapshot and conditional
capture to the existing exclusive `PreparedNativeCircuit`. Its additive public
intake contract below is approved; publication and external-consumer qualification
remain pending until their implementation evidence is recorded. The base
public `NativeCircuitPreparing` operations keep their ordinary nil-snapshot
semantics. The existing controlled child requirements supply explicit SDK snapshot
preparation, semantic profile, options and simulation parameters; Native constructs
the mandatory control from the original `SPICESourceResourceAccounting` and
cancellation token. It never accepts a caller-created replacement storage owner.
The same simulation parameters reach actual model setup and the snapshot.

```text
original source resource owner + fixed Native limits
    -> Native preparation control (one Native floor/delta ledger)
    -> actual model setup -> SDK controlled snapshot -> compiled actual devices
    -> complete axis/instance/concrete-producer inspection
    -> actual CoreOSDI sealed access -> operation-5 conditional capture
    -> same control / cumulative allowance / original snapshot and mapping leases
```

### Additive Public Controlled Intake

Status: the finite additive public boundary is implemented and qualified by the
separate-module evidence below. Its concrete-input restriction does not grant
common-family nonemptiness, a complete initial cover, Physical integration,
all-phase/all-history guarantees or release qualification.

`NativeConstitutivePreparationInputs` is the existing immutable intake value.
Its public initializer accepts the concrete SDK
`OSDINativePrecisionSessionPreparer`, semantic profile, precision options and
typed simulation parameters. The stored preparer remains package-visible through
the SDK protocol. An existing package-only initializer accepting any SDK preparer
is a trusted fixture seam for controlled failures; it is not an external setup or
certificate-authority extension point. No caller evaluator, proof result or
replacement accounting control is added to this public intake.
The existing [CoreOSDI policy and cleanup boundary](../../CoreSpiceOSDI/RangeExecution/DESIGN.md#additive-public-policy-and-cleanup-boundary)
owns the concrete public capture/range input constructors and accessible typed
cleanup retry owners used by higher Native operations.

| Existing API | Additive public contract |
|---|---|
| `NativeConstitutiveCircuitPreparing: NativeCircuitPreparing` | Publishes its native-only and explicit OSDI controlled preparation requirements; `NativeCircuitPreparer` implements those same operations |
| `NativeConstitutiveSPICEPreparing: SPICENativePreparing` | Publishes its explicit OSDI controlled preparation requirement; `SPICENativeSimulation` forwards the actual IO preparation into the circuit child protocol, then uses the existing finish path |
| Base `NativeCircuitPreparing` / `SPICENativePreparing` | Keep their current requirements, defaults and ordinary preparation semantics |
| `PreparedNativeCircuit` / `PreparedNativeSPICESimulation` | Retain their actual devices, source identities and private controlled backing; this intake does not publish the package capture, chart or algebra helpers |

The concrete SDK initializer is a source-binding condition. A different protocol
conformer could return a genuine snapshot from another setup with the same image,
descriptor and topology. Those shared attributes do not establish equality of its
setup with this circuit's actual model. The public path therefore uses the
concrete SDK controlled snapshot method, which compares the actual model's
immutable preparation before serialization. The package fixture seam must not be
used to claim independent source/setup authority.

CoreOSDI forms one `OSDIPreparationOptions` from the resolved model assignments,
instance assignments, explicit simulation parameters, operating temperature,
connected terminal count and evaluation limits. That same value reaches actual
native setup and controlled snapshot construction. Model/instance scope and Given
status stay typed; omitted assignments are not synthesized from resolved native
defaults. STRING input validity and exact controlled preparation comparison remain
SDK contracts, rather than a claim that arbitrary cold setup bytes have native
C-string semantics. Native's existing source, topology and compiled mapping
checks then bind the retained program to the actual circuit.

The controlled SPICE operation consumes the existing `PreparedSPICESimulation`
intent without source reread or reparse. It forwards that intent's circuit,
operating conditions, numerical limits and original resources to controlled
circuit preparation, then runs the existing `finishPreparation`. Source and
configuration identity, actual cold model facts and metadata reservations retain
their existing owners. This is an additive host API boundary, not an OSDI export,
root, trajectory or all-history certificate.

### Fixed Floor and Additional Storage

The ledger composes the existing Native allocation condition with the existing
source-global reservations. It creates neither an independent work quota nor a
replacement source-storage policy. Source-global live/temporary ceilings and
Native `maximumAllocationBytes` are separate simultaneous obligations.

| Phase / payload | Native accounting | Source-global accounting |
|---|---|---|
| Ordinary OSDI/preparation/compiler backing | Existing ordinary floor F; existing construction scratch is included at its simultaneous-live boundary | Existing reservations, once; the new control does not reserve these bytes again |
| SDK controlled snapshot construction | Every outstanding controlled reservation contributes X before allocation; require F+X+delta within the Native ceiling | One reservation through the same original resources; SDK release refunds it |
| Prepared publication | Seal at original retained ordinary F plus all outstanding controlled X; publish this sum as compileCapacity | Transfer existing leases without re-reservation |
| Capture/helper/copied coefficients/numerical scratch and output | New reservations contribute to the same post-seal delta; require original sealed floor plus all concurrent deltas within the ceiling | One reservation per distinct allocation; copies share their release owner |
| Release of a pre-seal snapshot lease after publication | Does not reduce the original sealed floor | Refund actual source reservation on its last release |
| Release of a post-seal delta lease | Subtract that exact delta once | Refund that reservation on its last release |

Before publication, explicit Native preparation boundaries set F to the existing
simultaneous ordinary capacity: initial foreign envelope, preparation retained plus
construction scratch, compiler retained plus compiler scratch, and immutable
metadata retained plus still-live compiler scratch. A failed floor update leaves
the previous valid floor unchanged. The final seal removes finished ordinary
scratch and folds each currently outstanding controlled reservation into the
original floor exactly once. No snapshot multiplier, measured RSS, or assumed SDK
allocation count substitutes for the SDK's actual controlled reservation calls.
The initial ledger's own logical stored fields are admitted before its creation.
Each wrapped reservation also admits its logical ticket/closure-capture fields;
these are distinct from the requested SDK payload and exclude allocator headers
and RSS. Immutable Native program inventory admits its own array payload/header
before copying program values; SDK program/setup backing remains shared.

Reservations are identified by their pre-seal or post-seal phase. A release from
the first phase can never subtract a later helper's delta. Publication occurs only
after all preparation callbacks have returned and the pending-admission count is
zero. Seal and floor changes explicitly reject a busy or reentrant admission;
unreserved tickets cannot be folded into the published floor. Ordinary scratch
is removed from F only after its matching reservation has released. The ledger admits a pending delta
under its unconditional `Mutex<State>`, releases the lock, then calls the source
owner. Source refusal rolls back only that pending delta. Every successful lease
retains the ledger and original source reservation until its last copy releases.
No source call, callback, model close or helper cleanup occurs under the ledger
lock. Native execution state may enter the ledger, but ledger code never enters
Native execution state: the fixed lock order is execution state then ledger state.

`NativeExecutionStorage` joins this ledger only for the explicit snapshot lane;
its ordinary nil lane retains existing byte and numerical behavior. Its existing
result-state validation remains valid, while every actual additional source
reservation also participates in the common ledger. Capture and numerical
allocation therefore cannot each spend the same remaining Native headroom.
`NativeCircuitPreparationRecord.valueEvidence()` retains the immutable snapshot
program owners and their admission, and preserves the original conservative
Native floor for this lane even after foreign model owners close. This floor is
not a claim about currently allocated payload or RSS. Closed foreign owners are
not retained merely to keep source programs alive.

Work checkpoints, including SDK controlled construction and the full declared
per-session scheduled maximum-work allowance, charge the same original source
work owner. The allowance is cumulative, is not actual-consumption telemetry, and
is not refunded on failure or close. All boxes and all instances retain this
control. This lane does not create a fresh Analysis numerical budget during
preparation or capture; ordinary numerical invocation ceilings retain their
existing independent meaning.

### Actual Device Inspection and Authority

A package borrowing operation on `PreparedNativeCircuit` validates the complete
compiled-axis bijection and every device/IR/name association before opening a
selected capture. Qualified concrete R/C/V producers must provide their existing
complete support and exact linear laws joined to that variable map. CoreOSDI owns
a sealed actual-device access function: it casts to its internal concrete bound
OSDI producer, rather than trusting a protocol name supplied by a custom device.
Every raw alias, ground entry, private body coordinate, thermal coordinate and
internal flow remains represented by the existing actual mapping. Unknown or
substituted producers refuse. No mutable device array or executable owner escapes.

The operation returns the existing noncopyable CoreOSDI conditional capture.
Retained immutable program copies preserve their SDK original leases; copied
claims retain their existing source/quotient/inventory admission. These facts do
not establish a complete global constant-linear kernel, independent charge
coordinates, a circuit root, continuation or any history guarantee.

### Failure and Verification Ownership

Failures preserve original resource/control causes. Unpublished model and helper
cleanup follows the existing OSDI lifetime and cleanupPending path; pending cleanup
retains every affected reservation until actual close completes. An inspection
failure does not consume or close the prepared circuit. A capture cannot silently
open through the ordinary nil-snapshot lane.

`close()` completes the foreign model/helper cleanup that it owns. It does not
release immutable preparation records or copied source-proof retention still held
by the caller. Their original reservations refund only at actual final owner
release; a closed but live record is not a zero-storage baseline.

The per-call capture cancellation token may differ from the original preparation
token. Inspection checks that call token before startup, and Native checks it and
Task cancellation again after awaiting the genuine lower session, before returning
any capture. The original request control remains attached to all subsequent
capture work. If the call is cancelled during startup, Native closes that actual
capture before refusal; a failed close preserves cancellation as the primary cause
and the existing lower cleanup failure and retry owner. SPICE delegation uses the
same Native boundary. Token identity is not an admission assumption.

`Tests/CoreSpiceOSDINativeTests/NativeConstitutivePreparationTests.swift` owns
actual Native preparation/capture tests against the original four pinned model
programs, setups, singleton domains, contexts and precision bits; ordinary missing
snapshot refusal; concrete-producer/complete-axis refusal; source and Native
capacity refusal before allocation; shared scheduled-work exhaustion; cancellation;
failed setup/helper cleanup; copied program/claim lifetime; and final exactly-once
refund. Existing lower CoreOSDI capture qualification remains a premise rather
than a substitute for this new Native execution-path evidence. This bounded
actual-preparation/capture lane is qualified by the owner evidence below; complete
global identities, circuit roots, continuation and all-history guarantees remain
outside this lane's authority.

The additive public intake requires one separate-module consumer with neither
`@testable` access nor the CoreSpice package identity. It uses the concrete input
initializer and both existing child-protocol existentials with actual qualified
SDK fixtures, checks resolved receipt/source bindings, and closes all owners before
checking final refunds. Capacity and cancellation refusals use those same public
entries. A separate compile-negative client must fail when passing an arbitrary
SDK preparer conformer to the public initializer. These new boundary checks reuse
the unchanged internal source/setup/capture evidence above; a public declaration
alone is not qualification. Consumer compilation and bounded runtime use the
matching frozen product closure rather than a new default all-products build.

The final separate-module client uses ordinary imports, with neither `@testable`
nor a CoreSpice package identity. Its existing public Native and SPICE child
protocols prepare the actual qualified `linear_rc` image through concrete SDK
inputs; resolved image/setup/source facts, capacity refusal, cancellation and
final-owner refunds pass. One public conditional Flow call also passes its finite
endpoint, source scope and contraction checks. The external execution receipt is
[public-preparation/external-r1/receipt.json](../../../.verification/prescribed-voltage-flow-20261020/public-preparation/external-r1/receipt.json)
(SHA-256 `c505b029dca184a1533e8c35afcdee1be484916cb1b3d7101673dd0b2e297186`).
Its `compiled.json` explicitly composes one positive compile/link and three
unchanged authority-negative runs with the corrected typed scope-negative and
the previously unexecuted snapshot-negative. The first scope witness inferred
`Void` and exited successfully; that red is preserved, not counted as a refusal.
The final five negatives reject the intended concrete-factory, sealed-evaluator
or borrowed-result boundary. No production or positive-client code changed for
that one-line negative-fixture correction.

Actual owner cleanup/cancel/refund evidence is tied to the same compiled product;
external pattern matching and fallible cleanup calls prove accessibility, rather
than an injected public pending-cleanup event. The Flow child records its new nine
declarations / ten cases with zero skips, plus unchanged prior Root/Chart reuse
(18 declarations / 19 cases). The four old `NativeConstitutivePreparationTests`
declarations skipped by the current fixture environment are excluded from pass
counts. The public-boundary comprehensive review closed with zero blockers.
These are finite source-bound qualification facts; the remaining family, initial
cover, Physical, history and release obligations are unchanged.


| Shared state / retained owner | Native storage and entry points | WASM / Embedded contract | Release / external calls |
|---|---|---|---|
| Constitutive floor/delta and pending tickets | One unconditional `Mutex<State>`; setPreparingFloor, seal and admission/release mutate only under that lock | No conditional raw-state implementation; the Native OSDI lane is not a WASM/Embedded runtime capability | Source calls and cancellation checks outside the lock; phase-bearing lease releases exactly once |
| Existing numerical storage counters | Existing unconditional `Mutex<State>` and original mutation entries; actual new-lane source reservations join the same ledger | Existing common declaration unchanged; no portable foreign-worker claim | No reverse ledger-to-storage lock entry; allocation failure rolls back ledger pending/delta |
| Immutable programs and copied claims | Original SDK backing, program inventory reservation and snapshot-derived capture retention | Immutable Sendable values; target availability follows the owning SDK/adapter | Last program/claim copy keeps its source admission; no ordinary model owner is retained merely for bytes |

### SPICE Metadata and Source-Reexecution Preallocation

Consuming `PreparedNativeCircuit.reservingRetainedStorage` owns the actual
preallocation boundary. For an ordinary owner it checks the original Native
capacity and performs the existing one source reservation. For a controlled owner
it admits a pending ticket against the common floor/delta peak, calls the same
source owner once outside the lock, then atomically folds that successful ticket
into the permanent Native floor. Failure or cancellation before commit removes
only that pending delta. Its returned reservation is retained by the updated
record and the actual constructed facts/validator; its final release refunds
source storage but never lowers that request's original conservative Native floor.
There is no attach-after-external-allocation operation or forgeable receipt join.
An older copied record still reaches the same live ledger and cannot bypass a
later floor increase. Before constructing the updated reservation array, controlled
admission also covers its new count-plus-one payload, the one-element concatenation
operand and both logical array headers; the existing old array is already in the
floor. Checked count-derived work is charged before that copy. This metadata and
the payload share one source reservation while the public payload receipt retains
its exact requested byte count.

`SPICENativeSimulation.finishPreparation` obtains this admission before constructing
its actual precision-configuration arrays. The controlled SPICE overload
uses actual Native preparation then the same finish path, retaining exact source,
configuration, program and setup identities. `NativeSourceCircuitDeviceBinding`
uses the same consuming boundary before physical-validation storage is constructed.
Its baseline source-reexecution row ledger instead uses an ordinary live delta
lease from the baseline control before reserveCapacity; that lease refunds at its
actual last owner rather than permanently growing the preparation floor.

NativeOSDIValueEvidence keeps legacy array-capacity accounting unchanged for the
ordinary lane. For controlled backing, private program/setup bytes are not reserved
again as immutable metadata: the retained program already owns their SDK lease.
NativePrecisionConfigurationFacts and SPICE identity encoding read the public
stored byte counts directly. These count-only paths allocate no byte extraction;
actual metadata/coordinate/parameter arrays still receive their existing checked
construction/coexistence admission before allocation.

The CoreOSDI controlled adapter bound excludes only the program/setup backing
already owned by its mandatory control; its point-state arrays and receipt remain
in the ordinary adapter envelope. Each combined point session additionally charges
its full explicit maximumWorkUnits once to that same source owner before startup,
as a nonrefundable scheduled upper allowance rather than consumed-work telemetry.
The ordinary nil-snapshot session retains its original accounting behavior.

The controlled public-fixture tests keep their explicit 16 MiB adapter envelope.
The added actual SPICE/binder test covers both that envelope's ordinary point
refusal and the existing actual-four-model 1 GiB adapter profile's success under
unchanged Native 4 GiB and source 8 GiB ceilings. These are explicit caller
profiles; no retry, default change or ordinary-capacity relaxation connects them.
Each of the four original model source/setup requests is a separate caller with
its unchanged source ceiling. Within that caller, point and capture allowances,
snapshot work and every repeated box share one owner; the test also asserts their
aggregate allowances across the four independent callers. Grouping all eight
1-billion-unit scheduled allowances under one 8-billion-unit owner leaves no
snapshot work and is an explicit quota refusal, not an admissible success fixture.

Finite qualification of this combined path includes actual SPICE finish/reexecution,
coexisting point/capture preparation, refusal/cancellation and cleanup/retry. The
capture-only frozen runtime remains an independently preserved lower-stage premise.

| Owner evidence | Qualified scope |
|---|---|
| Combined r5: 13 declarations / 17 cases, zero skips | Four original independent source/setup requests with point session absent/present, two same-domain identity queries per mode (16 total), actual SPICE finish and binder, shared work/storage, exact refusal and final refund |
| Cancellation r7: 2 declarations / 3 cases, zero skips; one finding-limited recheck closed | Distinct call-token cancellation during genuine startup, actual helper close, retained retry authority after cleanup failure, Native/SPICE delegation and owner reuse |
| Migrated metadata test: 1 declaration; remaining precision owner: 4 declarations, zero skips | Original worker/profile, one-byte-short refusal before source acquisition, one actual acquire/release, worker/semantic/program/numeric mismatch and cancellation |
| Ordinary Native owner: 57 declarations, zero skips, current objects relinked | Existing storage, sparse capacity, source reexecution and voltage-source inspection paths |
| OSDI owner partial run: 66 complete passed declarations including original full BULK N schedule | Actual finite composed nil path; the 120-second runner timed out during a different serialized full schedule and is not a whole-owner pass |
| Existing public-import borrower recompiled against current objects | Public API use without private/package flags, exact source/axis association, cancellation, callback cause and repeated borrow |

The twelve full original numerical schedules belong to a separately filterable
serialized suite with an eleven-minute suite allowance. The initial 120-second
whole-owner runner had the wrong granularity; its timeout and cleanup evidence
are retained. Completed events and the four remaining fast tests close affected
owner coverage. Unchanged equation/validator/solver kernels, exact legacy model
artifacts, worker/profile and source-program selection preserve the prior numerical
qualification premises; the remaining eleven long schedules are not claimed as
new executions. Source-diff and current-link records explicitly distinguish
preparation/control/lease changes from those unchanged physical premises.

Local qualification records are indexed by
`CoreSpice/.verification/native-constitutive-preparation-20261020/aggregate-r8.json`.
This evidence grants no global constant-linear-kernel, rank, root, flow or history
authority. Each actual-family source/setup request keeps its own unchanged ceiling;
all point/capture sessions and boxes within that request share the original owner.

The [Conditional Initial Cover](PrescribedVoltageInitialCover/DESIGN.md) child checks finite explicit-domain root coverage using the actual strong plane and existing root/value witnesses. Global initial-set inclusion remains separate.
