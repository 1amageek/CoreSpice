# BSIM4 4.5 Safe Evaluator

## Purpose and Scope

Status: B45-6 implementation contract; numerical qualification is Native CPU only. Parent:
[CompactModels](../DESIGN.md). No children. This component owns synchronized
safe access to [CoreSpiceBSIM45](../../CoreSpiceBSIM45/DESIGN.md), independently of
Parser, Lowering, Devices, Analysis, Foundation and Metal.

## Responsibilities and Boundaries

The public `BSIM45Evaluating: Sendable` protocol exposes preparation metadata,
DC/AC/transient evaluation, history initialization/commit and output-referred noise
as witness requirements. `BSIM45Evaluator` provides the implementation.
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

The protocol owns all operations invoked through an existential. The implementation
uses the following fixed-value call contract:

```text
BSIM45Configuration (separate numeric-ID model/instance buffers, exact schema)
 -> checked C admission and preparation -> immutable topology/diagnostics
BSIM45Evaluating.evaluate(SIMD16 bias, analysis, separate deficit coordinate)
 -> fixed residual/RHS/charge/Jacobians/states + safe trial token
initializeHistory / commit / reject / acceptedStates / noiseSpectrum
 -> same Mutex state and typed BSIM45Error
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

`BSIM45Error` distinguishes all native ABI failures; source/instance context is
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
The private trial-token constructor pairs the native generation with an
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

`CoreSpiceBSIM45KernelTests` use the real standalone C target:
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

## B45-6 Admission and Publication

`BSIM45Parameter` carries exact schema/role/selector, kind and evaluated SI value.
Devices converts resolved symbols once through the release schema; the evaluator
never searches model names, merges roles, scales dimensions or stores input buffers.
Duplicate selectors, mismatched role/schema/kind and invalid values fail before
publication. The C setter validates the compiled original ID/kind table.

The fixed result matrix uses stride 16; C ABI tuples are scoped Double buffers.
Conversion is a bounded value copy, not a zero-copy claim. No pointer escapes.
Every operation attempt invalidates pending authorization, including invalid SIMD
padding. Tokens contain a retained immutable evaluator identity and generation;
no raw C address escapes. Rejection invalidates only that trial.

Physical bias always has zero ground/unused/deficit/padding. Transient deficit is
a separate coordinate with the C release's exact scaling. RHS is J*x-residual,
using that coordinate only for the transient deficit column. Static/AC physical
results do not stamp a deficit constraint; Devices owns its reserved DC/AC row.

Retained payload is queried C owner bytes plus declared Swift stored payload and
actual diagnostic capacity/text. Existing configuration buffers are borrowed;
selector uniqueness storage and diagnostic conversion scratch are checked against
temporary capacity. Preparation work and the activated stress ceiling are charged
through the caller control before publication. C diagnostics include a bounded
source site/code/role/selector/value and text; conversion never invents 4.8.3 warnings.

BSIM45 charges its explicit stress ceiling inside safe construction, before C
preparation. Devices includes that already charged work in its receipt; it does
not charge the same work twice. Diagnostic text length is scanned within the
fixed C buffer before allocation, then actual Swift array capacity is checked.

A failed C preparation exports `BSIM45PreparationFailure` with its original
status and bounded structured diagnostics before destroying the partial owner.
The same diagnostic capacity checks apply on success and failure; inability to
retain complete diagnostics fails with capacity admission instead of truncation.

The 6.4.0 portable component probe links an explicit 1 MiB WASI stack. Debug
fixed-value frames exceed the default 64 KiB stack: the probe frame alone is
24,176 bytes and the matrix conversion frame is 6,128 bytes, nested below large
evaluation/C frames. Stack admission is a caller/runtime responsibility, separate
from the retained C owner and temporary preparation payload. Native/WASM/Embedded
use identical Mutex storage and access; no no-op synchronization is substituted.
Portable evidence covers these component sources and their contracts/C dependency,
not the unrelated BSIM3/4 source component Codable portability.
