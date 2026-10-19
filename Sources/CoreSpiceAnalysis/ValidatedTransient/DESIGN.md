# Validated Transient Scalar Barrier

## Purpose and Scope

This component owns only the finite affine scalar comparison test in the
[causal tube authority](../../../../TimingEngine/Sources/STAEngine/NativeExecution/ConservativeCoupling/DESIGN.md#finite-tube-checker).
Its parent is [CoreSpiceAnalysis](../DESIGN.md). It has no children.
It is an internal numerical checker, not an admitted causal transient profile.

## Responsibilities and Boundaries

Given exact finite binary64 proposal coefficients, check nonnegativity and the
comparison inequality on the entire closed slab. Model identity, constitutive
bounds, contraction, complete physical reconstruction, source-flow existence,
initial containment, all-history coverage, source phases and event identity remain
the caller's separate proof obligations. No solver or public API calls this
checker until those obligations have an executable owner.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Run budget and cancellation | Existing request ownership | No independent reset or owner |
| [NumericalState](../../CoreSpiceDevices/NumericalState/DESIGN.md) | depends on | CompensatedEnclosure arithmetic | Outward arithmetic and gradual underflow | Nonfinite projection fails |
| [Timing causal authority](../../../../TimingEngine/Sources/STAEngine/NativeExecution/ConservativeCoupling/DESIGN.md#finite-tube-checker) | used by, pending composition | Affine comparison inequality | Defines the mathematical premise | Scalar acceptance grants no physical certificate |
| [RangeExecution](../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | coordinates with | Same-source smooth-box scope | Separates missing source authority | Range values alone do not prove flow |

## Architecture

```text
exact affine radius proposal + supplied contraction/forcing bounds
    -> existing run work admission + cancellation
    -> compensated outward endpoint arithmetic
    -> nonnegative radii AND nonnegative barrier gaps at both endpoints
    -> conditional endpoint/radius bounds OR typed refusal
```

## Contracts and Invariants

For `0 <= t <= h`, the proposal is `R(t) = r0 + c*t`. Inputs require finite
`h > 0`, `alpha > 0`, `eta >= 0`, `r0 >= 0` and finite `c`. Here alpha is a supplied
lower contraction bound and eta a supplied uniform upper forcing bound.

Both R and `G = c + alpha*R - eta` are affine. Nonnegative outward lower bounds
for their two endpoints prove `R >= 0` and `R' >= -alpha*R + eta` at every point
of the slab, without sampling or an exponential approximation. Endpoint radius
and maximum slab radius are outward upper bounds. The checker may refuse a valid
equality case when rounding prevents a nonnegative lower bound; refusal is not a
proof that the physical system is unstable.

The returned scalar facts contain the checked proposal and are not initial-state,
entire-history, model, chart, domain, tube or event certificates. In particular,
caller-supplied constants are not promoted into physical authority.

## State, Ownership, and Lifecycle

Immutable scalar values only; no allocation, retained callback, foreign session
or shared mutable state is introduced. The existing request-owned
`TransientExecutionBudget` admits one fixed weighted scalar arithmetic envelope
before evaluation. Existing cancellation is checked before admission and before
publication. No retry or local budget reset exists.

## Failure, Concurrency, and Constraints

Invalid coefficients and uncertified proposals have distinct typed failures.
Existing numerical overflow, budget and cancellation failures propagate unchanged.
No partial facts are returned. Native/WASM/Embedded use the same value storage and
existing budget isolation; this component introduces no platform conditionals.

## Verification and Change Impact

[ValidatedTransientScalarBarrierTests](../../../Tests/CoreSpiceOSDIAnalysisTests/ValidatedTransientScalarBarrierTests.swift)
owns decreasing/increasing rational fixtures, a violation occurring only at the
last endpoint, the reversed-inequality counterexample, invalid geometry,
arithmetic overflow, cancellation and exact cumulative budget refusal.
These tests prove only the conditional scalar lemma. Real selected-source
chart/continuation, entire-history, threshold and persistence evidence remains
required by the Timing authority before PR20 can close.
