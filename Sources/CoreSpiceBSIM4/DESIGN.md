# CoreSpice BSIM4 Kernel

## Purpose and Scope

This standalone C design owns the exact Berkeley BSIM4 4.8.3 evaluator. Parent:
[CoreSpice](../../DESIGN.md). Child: [original physics](Kernel/DESIGN.md).
The registered Swift wrapper composes this exclusive C owner. Production binding
and Level 54 admission remain separate responsibilities; kernel availability
must not be interpreted as native production support.

## Responsibilities and Boundaries

The C context owns one model, instance, geometry knot, local topology, matrix,
trial/accepted/older states and bounded diagnostics. Original equations own
physical preprocessing, current, charge, analytic derivatives and AC NQS.
The external solver owns voltage limiting, convergence, integration-step
selection, run lifetime, cancellation and handle-access serialization. The C
ABI never retains input/output buffers. No SPICE frontend or simulator is public.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Registered standalone target | Production owns separate composition proof |
| [Safe evaluator](../CoreSpiceCompactModels/BSIM4/DESIGN.md) | used by | Exclusive opaque ABI | Synchronized Swift composition | Host evidence only |
| [Physics](Kernel/DESIGN.md) | child | Exact original equations | Isolated simulator ABI | Reproducible source adaptation |
| [BSIM3 kernel](../CoreSpiceBSIM3/DESIGN.md) | coordinates with | Ownership pattern only | Separate model contexts | Physics and eight-slot ABI are not reused |

## Architecture

```text
strict parameter admission -> original setup -> temperature/check
    -> exact-bias current/charge/load -> original complex AC load
                   |
          context-local trial token -> accept / reject
```

## Contracts and Invariants

- Release identity is exactly `4.8.3`, mapped explicitly to original numeric
  selector `4.83`. No other release is substituted.
- Model and instance parameter tables remain separate. Finite typed input is
  checked before C integer conversion, selector defaulting and geometry access.
- The caller supplies a positive stress-iteration budget before preparation.
  Original LOD stress evaluates `ceil(nf)` terms only when its original sa/sb/sd
  condition is active; exceeding the budget is a typed resource failure before
  temperature evaluation. Fractional nf and all original terms are preserved.
- One context contains at most 12 non-ground nodes plus ground, all 29 original
  history states and 169 complex matrix cells. Every original gate/body/series/
  charge-deficit node remains represented; topology returns role aliases.
- DC residual is the original load's matrix-times-bias minus equivalent RHS.
  Charge contains gate-mid and body-junction contributions at their actual nodes.
  AC returns original complex admittance, including frequency-dependent NQS.
- Backward Euler and trapezoidal trial evaluation preserve accepted/older
  history. Only a current successful transient token can commit once. Any new
  evaluation or failed evaluation invalidates the previous trial token.
- Original noise selector 1 is executable preprocessing, with the original
  `paramchk=1` nonfatal warning retained. Immutable topology metadata always
  records its maintainer qualification limitation, even with `paramchk=0`.
  The spectrum ABI below preserves this execution/qualification distinction.
- The caller explicitly selects noise-capable topology before preparation.
  This replaces original global task-job inspection; topology never changes
  after preparation. Original documented regularization remains diagnostic.

## State, Ownership, and Lifecycle

One zeroed allocation owns all state and is destroyed exactly once by the caller.
Original geometry allocation borrows its embedded knot; matrix pointers borrow
embedded storage until destruction. Names/tables are immutable. No mutable
file-global state, filesystem logging or retained caller pointers are allowed.
The C handle requires exclusive access. The registered Swift owner uses the same
`Mutex<State>` storage/isolation contract on Native, WASM and Embedded; host
verification does not qualify WASM/Embedded target synchronization.

## Failure, Concurrency, and Constraints

Parameter, release, allocation, numerical, history, resource-budget and diagnostic-capacity
failures are distinct ABI statuses. Failed preparation cannot be retried on a
partially initialized handle. Output is published only after finite checks.
Diagnostic storage is a fixed context-local buffer, with explicit overflow.
Original list traversal has one element and one geometry; stress work is caller
bounded and the original EOT iteration
bound is preserved. Context calls allocate no further storage. Destruction and
concurrent access must be serialized by the caller.

## Verification and Change Impact

[Standalone proofs](Proof) own cold admission, original reference comparisons,
full-node current/charge finite differences, AC/NQS, transient/history failures
and sanitizer lifecycle tests. The host suite exercises 22 independent OP
fixtures (including fractional-finger stress) and 24 AC comparisons, plus the
registered safe-owner suite and existing BSIM3 affected suite. Pin the original
archive and all adapted hashes.
Only selected BSIM4 oracle sources may be compiled. Runtime evidence is host
CPU only. Swift production DC/AC/transient, Metal, WASM and Embedded remain
separate required proofs before claiming their capabilities.

## Charge Multiplicity Correction

The [kernel adaptation contract](Kernel/DESIGN.md) owns the independently derived body/NQS
charge-multiplicity correction and immutable original-source provenance. This
composition assumes the corrected `mult_i * I`, `mult_q * Q` contract; affected
transient evidence must be rerun. The historical unit-factor evidence remains
limited to its original conditions. No selector, history or resource ABI changes.

## Noise ABI Composition

[Kernel](Kernel/DESIGN.md) owns exact local spectrum equations and synchronized
borrowed full-node gain semantics. The opaque owner accepts 13 complex node gains
and returns fourteen output PSDs. Accepted transient history is unchanged and
trial tokens are invalidated. A non-noise-prepared handle rejects spectrum.
No C-to-Swift callback or stored borrow is needed.


## Exact Owner Allocation Query

Status: approved S3 ABI addition; existing allocation/lifetime behavior is the
implementation premise. `size_t cs_bsim4_owner_size(void)` returns
`sizeof(CSBSIM4Handle)` in the same compiled adapter as create/destroy. It
requires no handle, performs no allocation or mutation, and exposes no private
structure. It is the exact byte count requested by the single owner calloc, not
an estimate inferred from public topology or a claim about allocator metadata.

The count includes every embedded model, instance, geometry, diagnostic buffer,
matrix and history block. Setup's redirected geometry allocation borrows embedded
storage; it adds no owner heap allocation. Create failure retains no allocation;
all partial preparation states remain destructible, and successful create requires
exactly one serialized destroy. The safe Swift consumer converts the query to
its checked UInt64 storage vocabulary before allocation/admission. Swift object,
parameter transformation and copied diagnostic storage are separate upper-layer
budgets, so no embedded block is counted twice.

ABI validation must compile/link/call the actual query, check it against the same
private handle sizeof in a C-owned fixture, and run create/failure/destroy lifetime
checks. Changing the embedded handle changes the returned count automatically and
requires safe-evaluator and Devices budget revalidation. The query changes no
model equations, parameter tables, setup work, noise or history semantics.
