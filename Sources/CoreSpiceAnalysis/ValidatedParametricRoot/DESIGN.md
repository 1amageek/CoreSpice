# Validated Parametric Root

## Purpose and Scope

This component is a child of [Analysis](../DESIGN.md), with no children. It owns
one bounded Pure Swift sufficient Krawczyk test for a supplied square real
parametric system. Native compile/runtime qualification and the combined chart
review are complete. It grants no source, circuit, chart-completeness,
continuation, flow or all-history authority.

## Responsibilities and Boundaries

The caller supplies the exact box Z, an exact represented center z0 in Z,
a center residual enclosure H(z0;P), an interval Jacobian enclosing Hz(Z;P),
and an explicit finite sparse Double preconditioner Y. The checker recomputes
both the outward Krawczyk image and the infinity-norm bound; proposal generation,
approximate inversion and source/parameter binding remain with the caller.

For each admissible parameter p, the caller must establish that the same actual
H is continuously differentiable on an open neighborhood of the entire convex
Z and that both supplied enclosures cover that H and its spatial derivative.
Any source guards, aliases, legal source-current sections or other domain
constraints must hold throughout that chart. Conditional source formula bounds
alone do not establish these premises. Parameter correlations may be enclosed
conservatively; no independent-realization assumption is made. A claim about an
empty parameter family is not evidence of a nonempty physical family.

## Related Designs

| Design | Relationship | Contract Used | Cautions |
|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Numerical component composition | No new solve/Newton attempt |
| [ValidatedMatrixRegularity](../ValidatedMatrixRegularity/DESIGN.md) | depends on | Sparse outward residual-row traversal and norm arithmetic | Existing admission quantities/order and regularity behavior remain unchanged |
| [SparseExecution](../SparseExecution/DESIGN.md) | depends on | Mandatory existing LinearSolverExecutionControlling | No new budget, reset, refunded work or absent control |
| [Compile](../../CoreSpiceCompile/DESIGN.md) | depends on | Immutable canonical square SparseStructure CSR | Validate borrowed shapes and canonical indices under checkpoints |
| [NumericalState](../../CoreSpiceDevices/NumericalState/DESIGN.md) | depends on | Exact normalized CompensatedValue and outward CompensatedEnclosure arithmetic | Never discard low components or use center-only comparisons |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | Actual-source chart consumer | Native owns the source/domain/equation join, not this numerical result |

## Architecture

```text
borrow exact lower/upper/z0, H0, sparse J and Y + explicit limits + existing control
    -> checked complete input/box validation
    -> admit Delta scratch and image output before allocation
    -> existing sparse residual rows D = I - YJ
       -> outward q = maximum absolute row sum
       -> image K = z0 - YH0 + D*(Z-z0)
    -> strict inclusion in the original endpoint box AND q < 1
    -> immutable image/norm/dimension with final-copy lease, or typed refusal
```

## Contracts and Invariants

The package-only numerical entry is:

```swift
static func certify(
    lower: borrowing Span<CompensatedValue>,
    upper: borrowing Span<CompensatedValue>,
    center: borrowing Span<CompensatedValue>,
    centerResidual: borrowing Span<CompensatedEnclosure>,
    jacobian: borrowing SparseStructure,
    jacobianValues: borrowing Span<CompensatedEnclosure>,
    preconditioner: borrowing SparseStructure,
    preconditionerValues: borrowing Span<Double>,
    limits: Limits,
    control: any LinearSolverExecutionControlling
) throws -> Result
```

This is the package-only numerical entry; it exposes no source/model evaluator. Limits explicitly
bound positive dimension, Jacobian nonzeros, preconditioner nonzeros, managed
workspace bytes and retained result bytes. No defaults or hidden control are
provided. Both matrix dimensions and all four vector lengths equal n > 0.
Each exact normalized endpoint pair is finite, lower < upper, and
lower <= center <= upper. Comparisons retain both components. CSR has canonical
sorted unique columns, bounded monotone row pointers and complete numeric spans;
absent entries mean exact zero. Input enclosures and every outward intermediate
bound must remain finite. Malformed inputs never become an uncertified root test.

The original box remains the exact endpoint product. Delta encloses each actual
asymmetric interval [lower-center, upper-center]. It is not replaced by a radius
about center computed from half the box width. A midpoint-centered symmetric
CompensatedEnclosure may conservatively enclose that asymmetric interval: choose
a finite represented midpoint using half-scaled endpoint arithmetic, then bound
both exact endpoint distances from that chosen center outward. Arithmetic error
is included. No rounded midpoint is substituted for the original endpoints.

For each row, first compute z0_i - sum_k Y_ik*H0_k. Reuse the regularity
accumulator for D_ij = delta_ij - sum_k Y_ik*J_kj, including its identity diagonal,
then add sum_j D_ij*Delta_j and independently accumulate the outward absolute row
sum. Accumulating each D entry before taking its absolute value preserves the
existing regularity cancellation behavior. Product candidates, exact zeros and
touched entries all consume work. There is no stored YJ product or dense inverse.

Success requires q < 1 and, for every coordinate, strictly positive certified
lower bounds of both K_i-lower_i and upper_i-K_i. Subtract compensated endpoints
before projecting a lower bound, using the existing center.bounds/radius outward
rule. A touching or unresolved endpoint refuses; contains-zero and q==1 do not
succeed. Widening caused by outward arithmetic may refuse a valid proposal but
cannot admit an invalid one. Overflow or unrepresentable finite bounds refuse.

For each admissible fixed p, T_p(z)=z-YH(z;p) maps Z into its interior and is a
contraction with bound q. Hence it has one fixed point in Z. Since q<1 makes YJ
invertible for every matrix in the nonempty supplied interval matrix, square Y
is nonsingular; the fixed point is the unique zero of H in Z. A separate numeric
rank or supplied invertibility assertion for Y is unnecessary. This is a
conditional numerical theorem, not a check of the caller's H/J/source premises.
No smoothness in p, continuation, root outside Z, global coverage or history
claim is derived.

The immutable result retains only n image enclosures, dimension, norm upper bound
and their lease. An indexed throwing image accessor returns a scalar value;
there is no mutable buffer or caller-supplied certificate protocol. The caller
retains the original input/source/domain association when composing that result.

## Runtime Flows

A single synchronous call checks cancellation and complete shape/CSR/value/box
inputs, preadmits capacities, initializes fixed arrays, traverses sparse rows,
checks strict inclusion and final cancellation, then publishes a complete result.
No callback invokes H, a model, an external process or source preparation.

The residual-row factoring is limited to the existing ValidatedMatrixRegularity
traversal. Its original entry retains its exact validation, three-array managed
capacity, initialization work, per-product/touched checkpoints, upward norm sums,
strict refusal and final checkpoint. A scoped internal row consumer may inspect
the current accumulator and touched list synchronously before reset; no span
escapes. This checker consumes that same row arithmetic once, not a second
matrix product. The original regularity result remains unchanged.

## State, Ownership, and Lifecycle

Inputs remain immutable caller-owned borrowed patterns/spans for the entire
synchronous call. Scratch consists of n Delta enclosures and the existing n-entry
residual accumulator, Bool markers and Int touched indices. Result storage is a
separate n-entry image array. Checked strides/counts and Array value headers are
admitted before initialization, including simultaneous scratch/output lifetimes.
Every initialized and traversed element is precharged to the same mandatory
control. The four immutable result fields also receive a constant four-unit
construction checkpoint before the final cancellation check. The result lease outlives all copied result references; scratch leases
refund on success, refusal, arithmetic error or cancellation. Work is cumulative
and nonrefundable. These are managed payload capacities, not allocator/RSS claims.

Scratch is O(n); borrowed input storage is O(n+nnz(J)+nnz(Y)). Product work is
P=sum_(i,k in Y) nnz(J row k), plus input validation, YH0 work and touched/reset
work. It is not bounded by input nnz alone and may be cubic for dense inputs.
Each structural product is charged before processing, so existing cumulative
work/cancellation limits can stop it without completing an oversized product.

| State | Native / WASM / Embedded representation and isolation | Release |
|---|---|---|
| Control | Same immutable Sendable protocol reference to existing synchronized owners | Existing caller owner |
| Numerical scratch | Same exclusive local arrays; no shared mutable state | Synchronous call end |
| Result | Same immutable Sendable image/dimension/norm/lease | Last copied result |

No unsafe pointers, target-conditional synchronization, independent counters,
shared workspaces or global caches are introduced. Native qualification will not
be reported as WASM/Embedded execution evidence.

## Failure, Concurrency, and Constraints

Invalid dimensions/limits/box/CSR/spans/nonfinite input, workspace ceiling and
result ceiling are typed component failures. A well-formed proposal failing q or
strict inclusion returns typed uncertified failure; it does not prove singularity
or absence of roots. Existing arithmetic, work, cancellation and storage causes
propagate without conversion to uncertified. No partial image/result is published.
All external control callbacks occur outside any component lock; the component
owns none.

## Verification and Change Impact

[ValidatedParametricRootTests](../../../Tests/CoreSpiceOSDIAnalysisTests/ValidatedParametricRootTests.swift)
owns the focused behavioral fixtures for independent dyadic Krawczyk images and norms,
noncommuting sparse products, parameter-uniform affine roots, asymmetric boxes
with off-midpoint centers, outside roots, endpoint touching and q==1 refusal,
singular Y, exact low-component margins, interval Jacobians containing singular
matrices, malformed CSR and finite/overflow/underflow behavior. Source-soundness
and guard admission belong to the Native chart's separate behavioral tests.

Control tests cover pre-spent cumulative work, initialization and structural
product refusal, cancellation before/after admission, original failure causes,
complete refunds, input immutability and copied-result lease retention.

Fixed Swift 6.4 release / MacOSX27.0 qualification passed all 16 new test
declarations and the affected existing regularity owner's 13 declarations
(14 expanded cases), with zero skips. The combined runtime reported 29
declarations in two suites. The lower source and original regularity tests stayed
unchanged throughout the subsequent Native composition qualification. The shared
regularity traversal retained its original arithmetic and admission quantities.

The new 10,000-row diagonal fixture verified that peak managed payload equals
the checked workspace-plus-result capacity, cumulative work is below the explicit
1,000,000-unit allowance, and final live managed bytes are zero. Its exact work
count and numeric image endpoints were not printed; the evidence consists of the
actual asserted bounds, including strict inclusion and the compensated low-part
margin. Managed payload is not allocator overhead or RSS. Existing regularity
fixtures separately printed 140,000 and 239,990 work units and 330,024 peak managed
bytes for their diagonal/tridiagonal cases, with full refunds.

The [focused qualification receipt](../../../.verification/validated-parametric-root-20261020/focused-r1.json)
records exact commands, source/package pins, counts and asserted image ranges.
The [combined chart review](../../../.verification/prescribed-voltage-chart-20261020/scoped-review-r1.json)
and its [targeted Native finding recheck](../../../.verification/prescribed-voltage-chart-20261020/finding-recheck-r1.json)
are closed; the lower numerical implementation required no review correction.
This is conditional finite numerical evidence on the qualified Native target,
not source-soundness, all-root coverage, parameter continuation, flow or history
authority. Root owns final package composition and integration qualification.

The mathematical reference is G. Alefeld, *Verified Numerical Computation for
Nonlinear Equations*, Krawczyk operator and Theorem 4, pages 14-17:
<https://na.math.kit.edu/alefeld/download/2009_Verified_Numerical_Computation_for_Nonlinear_Equations.pdf>.
The explicit contraction test here also makes the nonsingularity implication
independent of an approximate-inverse generator.
