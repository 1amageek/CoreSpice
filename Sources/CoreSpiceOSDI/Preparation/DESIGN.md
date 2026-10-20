# OSDI Preparation

## Purpose and Scope
Child of [CoreSpiceOSDI](../DESIGN.md); owns Preparation for all admitted analyses.

## Responsibilities and Boundaries
Implements its parent's adapter contract without owning physics or solver policy.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Adapter](../DESIGN.md) | parent | DC adapter contract | Native-only | Revalidate native consumers |

## Architecture
```text
setup -> fixed projection -> consuming binding -> exclusive evaluation
```

## Contracts and Invariants
See the single authoritative [adapter contract](../DESIGN.md#contracts-and-invariants).
Preparation bounds count and adapter bytes before allocation; runtime limits bound
native storage/workspace. Foreign evaluation and stamping execute outside locks.

### Atomic binding claims

Binding uses the [Devices claim transaction](../../CoreSpiceDevices/DESIGN.md#atomic-private-node-binding)
on the caller's invocation-local context. It never copies the complete context
for rollback, so accumulated node/branch claim sets are not copied per device.

```text
cancel/conditions checks -> complete raw/active/global/CSR mapping
 -> validate complete node and explicit branch proposals without mutation
 -> construct bound owner -> nonthrowing node + branch commit -> publish device
```

The node and branch preflights share the same exclusive synchronous context access;
no await, external callback, or fallible operation occurs between the preflights
and final commits. A missing/duplicate/previously claimed branch, invalid private
node, or invalid mapping leaves both claim sets unchanged. OSDI has explicit
owned branches and does not request the legacy implicit branch allocator.
Consuming preparation still transfers the same execution owner, projection,
noise and precision receipts; native evaluation/close exclusivity is unchanged.

`OSDIBindingAtomicityTests` injects failed node/branch proposals and CSR refusal,
then retries the valid production bind on the same context. Its opt-in
`bindingOnlyCPUScaling` harness records process CPU time at 256, 1024 and 4096
devices with fixed-size private-node/flow projections. Native loading, projection
creation and context construction occur outside the timed interval. The harness
measures consuming bind and retained bound outputs, and can run unchanged against
the rollback-copy implementation for comparison; it makes no allocator or
zero-copy claim. Enable `CORESPICE_OSDI_BINDING_SCALING=1` with the fixture manifest.

## State, Ownership, and Lifecycle
Prepared owners are noncopyable. Bound references share only an exclusive checkout
owner; explicit close destroys evaluator buffers before unloading its image.

## Failure, Concurrency, and Constraints
Typed failure preserves native cleanup owners and primary/secondary errors.
No candidate state is committed by DC evaluation. Cancellation closes unpublished
owners; concurrent/reentrant stamp or close returns busy.

## Verification and Change Impact
[Adapter tests](../../../Tests/CoreSpiceOSDITests) verify this child contract.
Parent NativeExecution verifies circuit composition and completed result cleanup.

### Adapter logical storage admission

`maximumAdapterBytes` admits a conservative logical peak before each allocation
phase. It is not an allocator/RSS measurement. S2 image bytes, metadata and native
workspace are separately bounded by load/evaluation limits. Caller input string
payloads and immutable S2 receipt payloads are borrowed/shared; their copied
container headers are charged here.

| Phase | Charged storage |
|---|---|
| Before IR validation/clone | Fixed control words; instance/optional-owner arrays; node/branch COW arrays; validation sets; copied node/branch name dictionary tables |
| Before native setup | Owner/model wrapper headers (`MemoryLayout`), prepared device/receipt/mapping records; raw/active/projection arrays and setup scratch; active input, immutable initial native slots, accepted/trial native slots and four raw Q/Iq buffers; projected noise records and bounded channel names; owned topology growth |
| During binding | CSR optional-index array, BOTH simultaneous pair→slot / slot→pair tables, identity table, variable-kind table and IR name-table growth |

Element strides use `MemoryLayout`. Arrays that copy original IR are charged from the actual retained `capacity`
of `ir.instances`, `ir.nodes` and `ir.branches`; copied `nodeNames` and
`branchNames` tables likewise use their retained `capacity`. Newly constructed
validation sets use element counts. Arrays that can grow are charged four times
their admitted logical capacity. Each dictionary/set uses a
power-of-two bucket bound of at least eight and at least four times its entry
count, one `UInt` of bucket metadata, and four simultaneous table generations;
this conservatively covers aggregate rounding, original COW storage and rehash
scratch. Fixed per-phase control charges cover array/dictionary headers and
bookkeeping. All products, sums and bucket growth fail on overflow before use.

Generated names are ASCII `osdi:<globalNodeID>` / `osdi-flow:<globalBranchID>`,
within 32 bytes on the admitted 64-bit target. Existing names are compared as
borrowed UTF8 with ASCII case folding; no lowercased copies or normalization
arrays are materialized. Collision refusal remains explicit. Long caller instance
names are retained once by input values and are not multiplied into private names.
Noise source names retain the admitted original descriptor strings as immutable
COW values; instance identity and source index are carried separately. Runtime
metadata/string budgets bound acquisition. The adapter charges projected record
capacity before native setup and twice the retained UTF8 name payload after setup
but before constructing the projected record array. Raw metadata backing remains
owned by the runtime; this logical charge is conservative sharing accounting,
not a claim of a second allocator footprint.

`OSDIAdapterCapacity` is the authoritative charge calculation. The focused
capacity test admits the former numeric-only estimate but refuses the new peak;
the long-name test checks bounded private names and collision refusal. The actual
33-case numerical matrix keeps the same 16 MiB adapter policy.

Reserved caller backing is part of COW admission even when count is small. The
capacity regression reserves modest extra capacity in input arrays/dictionaries,
then rejects a budget that admits the same counts with ordinary backing.

## S4D Explicit Precision Preparation

The existing ordinary `prepare` requirement remains unchanged. A second
`prepare(..., transientPrecision: OSDITransientPrecisionInputs?)` requirement
selects the optional lane. Its protocol default accepts nil through the ordinary
requirement and explicitly refuses nonnil for legacy conformers; it never reports
precision success from ordinary point evaluation.

`OSDITransientPrecisionInputs` retains a caller-supplied
`OSDIPrecisionSessionPreparing`, exact worker read intent/source, expected semantic
profile, declared qualified numeric profile, explicit runtime options and selected
bits. Native qualification owns profile-file/worker-byte binding. The adapter
prepares the ordinary live model first, snapshots that exact model/options through
the lower public factory, then asynchronously admits a separate precision owner.
Only stateless native models are admitted for precision; the ordinary native-state
lane remains unchanged. Any failure closes unpublished precision resources before
the ordinary model/image and preserves lower retryable cleanup ownership/errors.

`OSDITransientPrecisionReceipt` retains the immutable `OSDIPrecisionProgram`
(including full program/setup byte snapshots and digests), actual worker reference,
declared numeric profile, options and bits. Both the prepared device and its
bound `OSDITransientPrecisionProviding.transientPrecisionReceipt` expose this cold
inspection value. It is not execution authority and does not add an IR field.
Native's existing instance-index/name join persists it after consuming binding.

Before snapshot/allocation, adapter admission charges the runtime options' full
program and slab bounds for cold snapshot/receipt storage, precision owner/header
records, three additional active-coordinate buffers, and six raw Iq buffers.
The runtime independently owns its slab/arena bounds. `maximumAdapterBytes` is a
logical storage budget, not whole-process RSS. Receipts share immutable backing;
no program/setup byte arrays are materialized in the repeated stamp path.

```text
same native model + original options
 -> budget admission -> public precision snapshot -> async exact worker admission
 -> separate precision owner in Session + immutable receipt
 -> consuming bind preserves receipt on BoundDevice
```

The focused precision adapter tests own cold exact binding, insufficient capacity,
unsupported state/capability, byte/receipt preservation and explicit cleanup.

Preparation cleanup failure returns `OSDIAdapterFailure.cleanupPending(cause:owner:)`. The retained `OSDIExecutionLifetime` is explicit retry authority for the entire helper → ordinary model → library sequence; a lower helper failure cannot release the ordinary owner early. The caller retains this authority across retries; ordinary explicit lifetime close keeps its existing typed error contract.

Precision preparation uses one nonoptional lexical helper owner in the selected branch and consumes it directly into the execution owner. The ordinary branch constructs its owner separately. This keeps the async result ownership explicit without merging a mutable optional helper across the fallible setup scope.

The execution owner's dual-gate decomposition retains accepted/trial raw static F
and actual accepted coordinates/context in addition to Q/Iq. Base adapter capacity
admits eight node-sized Double planes; explicit precision adds fourteen planes
(candidate/accepted low coordinates plus accepted/trial Iq and F centers/radii).
These are fixed retained buffers, not per-trial allocation or an RSS claim. The
[execution contract](../DCExecution/DESIGN.md#canonical-accepted-step-equation-decomposition)
owns the source-mode/history and nonmutation semantics.


Same-trial original-gate source sharing is owned by
[Equation Execution](../DCExecution/DESIGN.md#same-trial-source-facts-for-both-original-gates).
Admission additionally covers ordinary F/Q plus candidate-coordinate planes and,
for explicit precision, the F/delta-Q low/radius and candidate-low planes. Owner
and record headers use their actual MemoryLayout; all planes are fixed at setup.
The execution design owns the exact scalar-copy counts and callback-lifetime
reason for the owned copies; this admission is a storage bound, not a zero-copy
or allocator/RSS qualification.

### Conditional Identity Snapshot Preparation

The package-only optional snapshot lane is owned by
[RangeExecution](../RangeExecution/DESIGN.md#preparation-and-actual-binding).
Its factory requirement forwards the same request control to the SDK controlled
snapshot operation. The public ordinary/point preparation requirements and nil
behavior remain unchanged. The source program retains its original controlled
backing; no heuristic snapshot allocation/work bound or unadmitted byte extraction
is used. Publication and qualification prerequisites are owned by RangeExecution.


### Controlled Point-Session Backing

When an explicit controlled constitutive snapshot and a point helper are requested
together, the point helper uses that exact same immutable program. The ordinary
adapter precision capacity includes the point-state arrays and receipt, while the
program/setup private backing is admitted only through the snapshot's mandatory
control. The point process mapping/arena remains separate physical storage owned
by its existing Native envelope. The default nil-snapshot adapter capacity still
includes legacy program/setup capacity and is unchanged.

Before the combined point session starts, its full declared maximumWorkUnits is
charged to the snapshot control as a nonrefundable scheduled upper allowance.
This is not actual-consumption telemetry. Control failure closes the unpublished
model through the existing cleanup path; no child is started after failed admission.
The same request control later governs every conditional capture and query.
