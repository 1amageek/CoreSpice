# BSIM4 4.5 Safe Evaluator

## Purpose and Scope

Status: proposed component; no Swift implementation is present. Parent:
[CompactModels](../DESIGN.md). No children. This component will own synchronized
safe access to [CoreSpiceBSIM45](../../CoreSpiceBSIM45/DESIGN.md), independently of
Parser, Lowering, Devices, Analysis, Foundation and Metal.

## Responsibilities and Boundaries

The public `BSIM45Evaluating: Sendable` protocol will expose preparation metadata,
DC/AC/transient evaluation, history initialization/commit and output-referred noise
as witness requirements. `BSIM45Evaluator` will provide the implementation.
No generic algorithm is overridable through this protocol. The original kernel
owns physics; this layer owns borrowing, status conversion, synchronization and
safe result publication. Devices owns the noncopyable preparation/binding lease.

The existing CompactModels target already depends on MOSContracts. Only the
separate native C target dependency is new; do not introduce a second schema layer.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CompactModels](../DESIGN.md) | parent | Evaluator composition | Independent Swift tests | No solver dependency |
| [4.5 C kernel](../../CoreSpiceBSIM45/DESIGN.md) | depends on | Opaque context, IDs, topology and borrowed buffers | Exact release physics | Exclusive C calls and destruction |
| [Schema](../../CoreSpiceMOSContracts/Schema/DESIGN.md) | depends on | Release-specific canonical numeric IDs | No repeated name lookup | No portable reverse dependency |
| [4.5 production](../../CoreSpiceDevices/BSIM45/DESIGN.md) | used by | Safe evaluator and immutable metadata | Preparation owner composition | Public receipt is not executable authority |
| [PreparationStorage](../PreparationStorage/DESIGN.md) | depends on | Local capacities and charged work | Exact owner admission | No guessed C struct size |

## Architecture

```text
BSIM45Configuration + borrowed parameter Span + explicit preparation limits
 -> checked original-ID admission -> Mutex<State(handle)> -> one cold setup
 -> immutable topology/diagnostics + fixed-size value results
 -> synchronous calls through the same Mutex -> exactly-once deinit destruction
```

Proposed interface shape (names are design, not existing declarations):

```swift
public protocol BSIM45Evaluating: Sendable {
    var topology: BSIM45Topology { get }
    var diagnostics: [BSIM45Diagnostic] { get }
    func evaluate(bias: borrowing BSIM45Bias, analysis: BSIM45Analysis,
                  minimumJunctionConductance: Double)
        throws(BSIM45Failure) -> BSIM45Evaluation
    func initializeHistory(at bias: borrowing BSIM45Bias)
        throws(BSIM45Failure)
    func commit(_ token: BSIM45TrialToken) throws(BSIM45Failure)
    func noiseSpectrum(_ input: borrowing BSIM45NoiseInput)
        throws(BSIM45Failure) -> BSIM45NoiseSpectrum
}
```

## Contracts and Invariants

Configuration fixes polarity, canonical release/schema/adaptation, ambient/nominal
temperature, requested capabilities and work/resource policy. Model and instance
parameter buffers stay separate and borrow only during construction. Generated
IDs are checked against the compiled release table before C setters execute.
Supplied values are never merged with defaults in a dictionary. Frontend-owned M
and IC scalar projections are consumed by Devices before native parameter setting.

Hot operations take fixed SIMD-backed local bias/gains and return fixed SIMD-backed
evaluation values. Original 29 states fit SIMD32; node padding fits SIMD16; real
and imaginary matrices use four SIMD64 blocks each. Only active local slots are
authoritative, with zeroed padding. No per-bias parameter names, dictionaries,
arrays, native setup or heap allocation. Diagnostics materialize at preparation
or failure boundaries and their retained capacities are budgeted.
Fixed result values require a bounded ABI transfer; measure these bytes/copies
instead of claiming zero-copy merely from SIMD use. Borrow C output storage within
the locked call where the safe interface permits it, without escaping its lifetime.

`BSIM45Failure` distinguishes all native ABI failures; source/instance context is
attached by the preparation caller. It never reports an unsupported operation as
an empty successful matrix/spectrum. Capability metadata describes the compiled
and verified operation set, separately from physical/model qualification.

## State, Ownership, and Lifecycle

| State | Native / ordinary WASM / Embedded storage | Entry points and release |
|---|---|---|
| C handle/history/trial generation | Same private `Mutex<State>` | Every evaluate/init/commit/noise call; serialized deinit destroy |
| Topology, source IDs and preparation diagnostics | Same immutable Sendable values | Constructor publication / reads / object lifetime |
| Borrowed parameter and result pointers | Scoped closure, never stored | Construction or one locked C call only |

Construction checks owner size/resource admission before create. Every subsequent
failure destroys the partial handle once before throwing. Successful construction
transfers ownership to the locked state. The public evaluator may support shared
synchronized calls; the consuming production owner must not leak an evaluator
reference that allows an independent run to acquire its mutable history.
No I/O, await, callback or external event emission runs under the lock.
The proposed private trial-token constructor pairs the native generation with an
immutable per-evaluator identity object. Tokens retain only that identity marker,
never a raw context pointer or the evaluator. Commit checks identity before the
C call; stale tokens cannot alias a later context at a reused allocation address.
This needs no mutable process-global counter and keeps the same target contract.

## Failure, Concurrency, and Constraints

Preserve the existing preparation budget's separation of retained payload,
temporary peak, diagnostics and work. The C owner-size query is exact requested
allocation; allocator metadata, process RSS and shared immutable buffers are
reported separately and not double counted. No target-specific raw state replaces
Mutex. Source portability does not establish target runtime qualification.

## Verification and Change Impact

Proposed `CoreSpiceBSIM45KernelTests` will use the real standalone C target:
both polarities, exact release/schema refusal, SC correction, omission/defaults,
resource admission, original references, all local derivatives, history failures,
noise and concurrent calls. Native ASan/UBSan owns pointer/lifetime proof; supported
TSan runs own concurrent access/destroy safety. No mock supplies final kernel proof.

Measure release-build repeated bias calls and one preparation separately: native
owner allocations, Swift allocation/copy counters and cold setup count. Enforce
zero per-bias name searches, expression evaluation and setup. Compare retained
capacity with actual owner-size queries and measured allocation categories.
Pure schema targets retain the fixed Swift 6.4.0 Native/WASM/Embedded compile,
link and minimal runtime matrix. Numerical 4.5 execution is initially Native CPU
only; numerical WASM/Embedded needs its own target proof before advertised support.
