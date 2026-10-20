# Validated Transient Numerical Checks

## Purpose and Scope

This component owns finite conditional affine-barrier and Picard-slab numerical
checks. Its parent is [CoreSpiceAnalysis](../DESIGN.md); it has no children. The
barrier relates to the [causal tube authority](../../../../TimingEngine/Sources/STAEngine/NativeExecution/ConservativeCoupling/DESIGN.md#finite-tube-checker).
Neither check is an admitted physical source or entire-history profile. The new
Picard implementation and behavioral fixtures await qualification.

## Responsibilities and Boundaries

The existing scalar barrier, given exact finite binary64 coefficients, checks
nonnegativity and the comparison inequality on the entire closed slab. Model identity, constitutive
bounds, contraction, complete physical reconstruction, source-flow existence,
initial containment, all-history coverage, source phases and event identity remain
the caller's separate proof obligations. No solver or public API calls this
barrier until those obligations have an executable owner. The new package-only
Picard checker validates a supplied initial set, uniform field enclosure and
q-Lipschitz bound against an explicit convex q box. Its caller owns their actual
source, chart, common time/input-family and regularity binding; supplied numbers
cannot create that authority.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Run budget and cancellation | Existing request ownership | No independent reset or owner |
| [NumericalState](../../CoreSpiceDevices/NumericalState/DESIGN.md) | depends on | CompensatedEnclosure arithmetic | Outward arithmetic and gradual underflow | Nonfinite projection fails |
| [Timing causal authority](../../../../TimingEngine/Sources/STAEngine/NativeExecution/ConservativeCoupling/DESIGN.md#finite-tube-checker) | used by, pending composition | Affine comparison inequality | Defines the mathematical premise | Scalar acceptance grants no physical certificate |
| [Chart Evolution](../../CoreSpice/NativeExecution/PrescribedVoltageEvolution/DESIGN.md) | prospective consumer | Source-bound qDot and q-Lipschitz bounds | Native composition | Common AC family/time and q-domain admission remain with Native/host |
| [Linear solver control](../../CoreSpiceCompile/SparseFactorization/DESIGN.md) | depends on | Work/cancel/storage admission | Mandatory caller owner | Picard creates no budget or control |
| [RangeExecution](../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | coordinates with | Same-source smooth-box scope | Separates missing source authority | Range values alone do not prove flow |

## Architecture

```text
exact affine radius proposal + supplied contraction/forcing bounds
    -> existing run work admission + cancellation
    -> compensated outward endpoint arithmetic
    -> nonnegative radii AND nonnegative barrier gaps at both endpoints
    -> conditional endpoint/radius bounds OR typed refusal

exact Q + Initial + uniform F/h/L + original cumulative control
    -> validate all borrowed inputs and capacities before allocation
    -> Initial subset Q AND endpoint E = Initial + h*F subset Q
    -> strict outward h*L < 1
    -> one admitted immutable endpoint array OR typed refusal
```

## Contracts and Invariants

### Scalar barrier

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


### Conditional Picard slab

```swift
package static func certify(
    lower: borrowing Span<CompensatedValue>, upper: borrowing Span<CompensatedValue>,
    initial: borrowing Span<CompensatedEnclosure>, field: borrowing Span<CompensatedEnclosure>,
    duration: CompensatedValue, lipschitzUpperBound: Double,
    limits: Limits, control: any LinearSolverExecutionControlling,
    cancellation: CancellationToken
) throws -> Result
```

`ValidatedPicardSlab` is a non-swappable numerical algorithm. Its explicit Limits
contain maximumDimension and maximumResultBytes. It requires positive dimension,
matching spans, exact ordered finite Q endpoints, finite Initial/F enclosures,
exact represented h>0 and finite L>=0. A singleton Q coordinate is allowed; an
empty vector, reversed axis or invalid ceiling refuses before allocation.

For each fixed admitted time/input history, the caller must prove that its
Caratheodory field on the ENTIRE convex Q and closed duration is uniformly in F
and q-Lipschitz with bound L. Every initial value is in Initial. Lower only checks
Initial subset Q, E=Initial+h*F subset Q, and outward h*L<1. For any tau in [0,h],
the integral of a bounded field lies in tau*F. The set Initial+tau*F is contained
in hull(Initial,E), a subset of convex Q by the two inclusion checks. Therefore
the Picard operator maps the closed Q-valued continuous-path set to itself and
has contraction factor at most hL, CONDITIONAL on the caller's field and family
premises. A fixed initial point and history have the conditional unique fixed
point; the result does not choose a common solution across different histories.

CE multiplication/addition and compensated gap comparisons retain DD low
components and outward rounding. hL==1 refuses. Underflow cannot erase a positive
product; overflow/nonfinite projection never becomes a zero bound. Conservative
rounding may refuse a valid boundary-touching case. It is not proof of escape,
nonexistence or loss of uniqueness.

The private Result constructor retains only dimension, duration, the checked
contractionUpperBound, endpoint[n] and its original lease. endpoint(at:) returns
CE data after an index check. Initial/source/field callbacks are not retained.
The numerical result has no physical trajectory, source, root, chart-cover,
continuation, event or entire-history authority.

## State, Ownership, and Lifecycle

The barrier retains immutable scalar values only; no allocation, callback or
foreign session is introduced. The existing request-owned
`TransientExecutionBudget` admits one fixed weighted scalar arithmetic envelope
before evaluation. Existing cancellation is checked before admission and before
publication. No retry or local budget reset exists.

Picard borrows all input spans synchronously. It uses the actual caller's
LinearSolverExecutionControlling plus mandatory per-call B/Task cancellation,
checked before/after each scheduled operation and before publication. Shapes,
all finite/ordered values, checked byte arithmetic and result cap are validated
before a single result reservation/allocation. Scalar arithmetic scratch is
constant stack storage; the sole n-CE initialized result buffer transfers without
another materialization. Validation, inclusion, scalar contraction, initialization
and endpoint operations are all precharged. No O(n) workspace, independent
budget, source evaluation, unsafe buffer or async borrow is added.

| State | Owner/isolation | Release |
|---|---|---|
| Input spans | Caller-retained owners, immutable synchronous borrow | Call exit |
| Work/storage/cancellation | Original provided control and per-call token | Existing ownership |
| Endpoint array and result metadata | Immutable Result with one admitted lease | Last result copy |
| Mutable scalar/array computation | Operation-local only | Failure or transfer |

There is no new shared mutable production state or target conditional. Tests use
unconditional Mutex state; reservation callbacks execute outside that lock.
Native/WASM/Embedded shared contracts are unchanged; Native runtime qualification
will not be generalized to unexecuted targets.

## Failure, Concurrency, and Constraints

Invalid coefficients and uncertified proposals have distinct typed failures.
Existing numerical overflow, budget and cancellation failures propagate unchanged.
No partial facts are returned. Picard distinguishes invalidInput,
nonFiniteInput, resultLimit, selfMapUncertified and contractionUncertified.
Numerical arithmeticOverflow and original control failures propagate unchanged;
per-call cancellation uses AnalysisError.cancelled. Failure after allocation
releases the same result lease; work is cumulative and is never refunded/reset. Native/WASM/Embedded use the same value storage and
existing budget isolation; this component introduces no platform conditionals.

## Verification and Change Impact

[ValidatedTransientScalarBarrierTests](../../../Tests/CoreSpiceOSDIAnalysisTests/ValidatedTransientScalarBarrierTests.swift)
owns decreasing/increasing rational fixtures, a violation occurring only at the
last endpoint, the reversed-inequality counterexample, invalid geometry,
arithmetic overflow, cancellation and exact cumulative budget refusal.
These tests prove only the conditional scalar lemma. Real selected-source
chart/continuation, entire-history, threshold and persistence evidence remains
required by the Timing authority before PR20 can close.


[ValidatedPicardSlabTests](../../../Tests/CoreSpiceOSDIAnalysisTests/ValidatedPicardSlabTests.swift)
owns exact dyadic positive/negative field endpoints, initial-only and endpoint
self-map counterexamples, hL boundary and >1 refusals, DD-low comparison,
nonzero underflow/overflow, empty/shape/finite/capacity refusals, cumulative work,
pre/mid cancellation, failed reservation, linear managed result payload and
last-copy refund. Existing barrier implementation is unchanged; its focused
behavior remains the direct compatibility check for the component extension.
No actual source-family or whole-history theorem is claimed from these fixtures.

The finite Native qualification is recorded in
[qualification-r5.json](../../../.verification/validated-picard-slab-20261020/qualification-r5.json).
All 12 Picard and six unchanged barrier declarations pass with zero skips on
Swift 6.4/macOS SDK 27. The initial compile failure was confined to two throwing
test expressions; precomputing their expected values preserved both predicates.
Production arithmetic, control and resource paths were unchanged. The one
combined scoped review closed without a blocking finding. This evidence does
not qualify unexecuted targets or discharge physical source/continuation premises.
