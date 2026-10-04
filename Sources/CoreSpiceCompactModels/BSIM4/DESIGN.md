# BSIM4 Safe Evaluator

## Purpose and Scope

This component exposes the original BSIM4 4.8.3 kernel through safe values and
one synchronized owner. Parent: [compact models](../DESIGN.md). It does not own
production Level 54 binding, solver convergence or correlated noise analysis.

## Responsibilities and Boundaries

The safe owner validates parameter provenance/capacity and padding, performs
cold numerical admission, retains immutable topology/diagnostics/qualification
limitations, and serializes every C call and destruction. Original physics
belongs to [the C kernel](../../CoreSpiceBSIM4/DESIGN.md).

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Compact models](../DESIGN.md) | parent | Evaluator composition | Safe public values | Level 54 production remains closed |
| [C kernel](../../CoreSpiceBSIM4/DESIGN.md) | depends on | Exclusive opaque owner, fixed buffers | Exact original physics | Lifetime and every access share one lock |

## Architecture

`configuration -> exclusive cold setup/probe -> Mutex<State(handle)> -> value outputs`

## Contracts and Invariants

Bias/residual/charge are SIMD16 values with 13 active ABI slots; indices 13...15
must remain zero. Matrices compose four SIMD64 blocks with stride 16; padding is zero. All 29
history states are preserved in SIMD32. Model and instance dictionaries remain
separate. The caller explicitly supplies a positive maximumStressIterations;
original LOD work above this budget fails without changing the model. Parameter scopes are bounded by original table counts 886/36, and normalized-name collisions
are rejected. Runtime attempts invalidate prior transient tokens before input
validation; failure leaves accepted history unchanged. Checked errors propagate.
Original mult_i scales current/derivative OP values; mult_q scales intrinsic
charges and physical terminal charge. Intrinsic charges retain original polarity
normalization, whereas terminal charges use physical node orientation.

## State, Ownership, and Lifecycle

Native, WASM and Embedded source use the same `Mutex<State>`, opaque owner, entry
points and deinit. Setup is exclusive before publication; failed setup destroys
the handle once. Deinit frees under the same lock. No I/O, callback or suspension
occurs within it. Fixed C arrays import as tuples rather than lifetime-carrying
Span interfaces; scoped raw-byte borrows with exact Double element counts bridge
these arrays. Input borrows never escape and result tuples copy into independently
owned SIMD storage. No pointer or C struct is public in Swift.

## Failure, Concurrency, and Constraints

Unsupported release, invalid parameter/configuration, rejected original model,
nonfinite evaluation, allocation, resource-budget, diagnostic-capacity and history failures are
distinct typed errors. A failed attempt cannot become a zero successful stamp.
Mode1 qualification limitation remains immutable even if paramchk suppresses
its nonfatal warning. Runtime capability does not imply maintainer/foundry trust.

## Verification and Change Impact

[CoreSpiceBSIM4KernelTests](../../../Tests/CoreSpiceBSIM4KernelTests) exercises
cold success/failure, original-reference fixtures, padding, all topology roles,
history token rejection and concurrent evaluations. C standalone finite
differences/sanitizers cover the original physics boundary. The shared-state
review matrix is identical by source: all targets store `Mutex<State>`, read and
mutate through its closure, and release in locked deinit. Host CPU compile/link/
runtime is the verified platform; WASM/Embedded runtime is explicitly unverified.
Metal and production Level54 DC/AC/transient require separate composition proof.
