# Validated Sparse Matrix Regularity

## Purpose and Scope

Child of [Analysis](../DESIGN.md), with no children. Own a bounded Pure Swift
sufficient test for regularity of an explicitly supplied square interval matrix:
for the exact represented sparse R, certify sup_M ||I-RM||_infinity < 1.
The proposal generator and caller's source/domain/rank interpretation are separate.
Status: native behavioral qualification completed; see Verification and Change Impact.

## Responsibilities and Boundaries

The checker independently recomputes the product and norm bound. It does not
construct an approximate inverse, factor a matrix, choose anchor points, identify
physical charge rows, or certify roots, flow, histories or source completeness.
A caller may assemble columns from different legal Q anchors, including the two
independent columns of Q=(t,t^2); a single derivative direction does not determine
that matrix's rank. The caller owns all such identities and domain coverage.
The derived mathematical invariant is not replaceable by a caller protocol.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Numerical run ownership | No solve/Newton attempt is added |
| [SparseExecution](../SparseExecution/DESIGN.md) | depends on | Existing cumulative budget/storage/cancellation bridge | Both budget and storage are mandatory |
| [Compile](../../CoreSpiceCompile/DESIGN.md) | depends on | Immutable SparseStructure CSR | Cooperative canonical validation is repeated here |
| [ValidatedParametricRoot](../ValidatedParametricRoot/DESIGN.md) | used by | Scoped residual-row arithmetic | Same original regularity work/storage/order; root/source premises stay outside regularity |
| [NumericalState](../../CoreSpiceDevices/NumericalState/DESIGN.md) | depends on | Outward CompensatedEnclosure operations | Nonfinite projections refuse |

## Architecture

```text
borrowed canonical CSR M/R + borrowed E/Double value Spans + explicit limits
    -> bounded full shape/coordinate/numeric validation
    -> existing run owner admits one O(n) workspace lease
    -> row-sparse outward I-RM, touching only reached columns plus identity
    -> outward absolute row sums -> strict maximum < 1
    -> conditional dimension/norm fact, or typed refusal
```

## Contracts and Invariants

Inputs reuse SparseStructure; its row pointers and columns remain owned by the
caller. Values are borrowed Spans: M uses CompensatedEnclosure, whose real domain
is center.high+center.low plus/minus radius, and R uses finite exact represented
Double coefficients. Absent coordinates denote exact zero. Both matrices must
have the same positive dimension, row pointers of length n+1 beginning at zero
and ending at the exact values/columns count, monotone bounded row ranges and
strictly increasing in-range columns. Every value and finite outward absolute
bound is checked. n=0, mismatches, noncanonical CSR and nonfinite inputs refuse.
No Array, dictionary or triplet representation of input values is materialized.

Limits explicitly bound dimension, each input nonzero count, and managed workspace
payload bytes; no guessed defaults are provided. The existing run budget's matrix
ceiling also applies. Checked n+1, stride, byte and work arithmetic precede
allocation or traversal. All input validation runs before workspace allocation.

For row i the checker begins with identity entry D_ii=1. For each R_ik it visits
row k of M and accumulates D_ij -= exact(R_ik)*M_kj with compensated outward
multiplication/subtraction. R zero coefficients are still visited and charged;
product candidates are charged before processing, including zero interval terms.
Identity is included even if no product touches the diagonal. A scoped internal
consumer may borrow the accumulated row and touched indices before reset for the
parametric-root checker; no row view escapes, no second product is required, and
the original regularity path keeps its exact admission and arithmetic order. There is no dense
n-by-n product, dense factorization, numeric rank guess or per-row n scan.

Each accumulated enclosure contains the corresponding entry of I-RM for every
admitted M. Its finite absoluteUpperBound bounds that entry's real absolute value.
For nonnegative finite running sum s and bound a, s=a=0 stays exactly zero;
otherwise fl(s+a).nextUp bounds the real sum under the existing round-to-nearest,
gradual-underflow arithmetic contract. Any nonfinite sum or upward projection
refuses. The maximum such row bound q therefore encloses sup_M ||I-RM||_infinity.
Success requires q < 1 strictly; q==1 never succeeds. A partial nonnegative row
sum reaching one may terminate as uncertified, without publishing a global norm.

Since q<1 makes RM invertible by the Neumann-series criterion, finite square M
and R are invertible. R needs no separately supplied invertibility claim. Failure
to establish this sufficient condition is uncertified, not a singularity verdict.
The immutable internally constructed result contains only dimension and outward
normUpperBound. It retains no input, workspace, callback or executable authority.

## Runtime Flows

One synchronous operation receives explicit limits, the existing nonoptional
TransientExecutionBudget and AnalysisResultStorageAccounting, and the existing
CancellationToken. It constructs AnalysisLinearSolverControl with those same
owners, checks shape/canonical/value input under checkpoints, admits storage,
charges every initialized element, evaluates rows, checks cancellation again and
returns only a complete strict result. No operation resets counters or retries.

The actual Native global-charge composition may use the controlled entry with
its existing mandatory LinearSolverExecutionControlling owner and explicit
Limits. Its Native caller enforces the prepared matrix ceiling. The original
budget/storage entry retains its additional budget matrix-dimension check and
forwards to the same numerical implementation. Neither entry constructs or
resets a budget, accepts an absent control, or changes the regularity criterion.

## State, Ownership, and Lifecycle

One lease covers exactly three fixed n-element arrays: CompensatedEnclosure row
accumulator, Bool visited markers and Int touched indices, plus their Array value
headers. This is a managed logical-payload capacity, not allocator overhead/RSS.
The arrays are initialized once. Only touched slots are summed and reset between
rows; fixed touched storage never grows. The lease surrounds the complete local
array lifetime and refunds on success, refusal, arithmetic failure or cancellation.
Input patterns and value owners outlive the synchronous borrow, with no pointer
escape, unsafe code, shared workspace, new global state or input copy.

| State | Native / WASM / Embedded isolation | Release |
|---|---|---|
| Numerical counters | Existing common Mutex-owned run budget | Existing run owner |
| Cancellation | Existing token atomic and Task contract | Existing caller |
| Storage counters | Existing synchronized caller accountant, called outside budget lock | Final lease |
| Row arrays | Local exclusive values, identical on every target | Before enclosing lease ends |

## Failure, Concurrency, and Constraints

Invalid shape/CSR/value, explicit workspace ceilings and uncertified norm have
separate typed component failures. Checked capacity arithmetic, numerical overflow,
existing work/storage exhaustion and cancellation preserve their original typed
causes. No resource failure is converted to uncertified or singular. Success is
never returned from a partial row/matrix. Storage admission occurs outside the
budget lock; this component owns no lock. Inputs may share immutable source
patterns; no mutation is performed.

## Verification and Change Impact

[ValidatedMatrixRegularityTests](../../../Tests/CoreSpiceOSDIAnalysisTests/ValidatedMatrixRegularityTests.swift)
owns independent small rational/dyadic reference products and interval corners,
strict-boundary and wrong-R counterexamples, intervals containing a singular
matrix, empty/nonfinite/noncanonical input, checked capacity overflow, mandatory
work/cancel/storage refusal and final lease refunds. Malformed CSR fixtures use
Compile's test-only unchecked construction so they exercise this checker.
A roughly 10k diagonal/tridiagonal fixture records runtime, cumulative actual
product work, peak logical workspace and refund while excluding n-by-n storage.
Borrow proof comes from the Span/immutable-source implementation and behavior;
measured managed capacity is reported separately, without a zero-allocation claim.
Focused native qualification does not establish other-target execution or the
caller's global S/domain/anchor/source/physical continuation obligations.

Fixed Swift 6.4 / SDK 27 release qualification passed all 13 focused test
declarations (14 expanded cases), followed by all 33 tests in the four-suite
CoreSpiceOSDIAnalysisTests owner, with no skips. The 10,000-row diagonal and
tridiagonal checks consumed 140,000 and 239,990 cumulative work units; each admitted
330,024 managed workspace bytes and refunded the full lease. The coordinated
comprehensive source/behavior review reported no findings. Exact commands, hashes,
phase runtimes and the retained first test-compilation failure are recorded in the
[qualification receipt](../../../.verification/validated-matrix-regularity-20261019/final-verification-r2.json).
This evidence is conditional finite-matrix native evidence within the scope above.
