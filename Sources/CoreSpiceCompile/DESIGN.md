# CoreSpiceCompile

## Purpose and Scope

This SwiftPM module owns sparse topology and numerical compile products. Parent: [CoreSpice](../../DESIGN.md). Children: [Sparse factorization](SparseFactorization/DESIGN.md) and [sparse ordering](SparseOrdering/DESIGN.md).

## Responsibilities and Boundaries

Compilation consumes canonical node and branch connectivity and validates prepared MOS receipts before constructing sparse topology. It does not prepare devices or infer compact-model auxiliary topology.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Owned module boundary | Revalidate direct consumers when contracts change |
| [IR MOS instances](../CoreSpiceIR/MOSInstances/DESIGN.md) | depends on | Prepared stage | Sole MOS value authority | Reject resolved or absent stage |
| [Preparation contracts](../CoreSpiceMOSContracts/Preparation/DESIGN.md) | depends on | Receipt identity and topology | Portable admission evidence | No Devices dependency |

## Architecture

```mermaid
flowchart LR
    Input[Typed inputs] --> Owner[CoreSpiceCompile]
    Owner --> Output[Validated outputs or typed failure]
```

## Contracts and Invariants

All physical, owned auxiliary, and referenced node pairs receive the required local CSR entries. Auxiliary variables have ordinary MNA indices and are never collapsed into physical ports.

Classic MOS types nmos/pmos and their l1/l2/l3 forms require prepared stage.
Legacy native l49/l54 forms fail with explicit OSDI preparation requirements.
The exact receipt release and polarity must match the type, and receipt instance
identity must match Instance.name. Exactly four physical ports, no classic owned nodes or branches, and node inventory
membership are checked before sparse construction. OSDI topology has its own
prepared instance contract and is not interpreted as a classic MOS receipt. Resolved stage and generic legacy model/parameter dictionaries do
not admit MOS compilation. Non-MOS compilation retains its existing algorithm.

```text
Instance.mos -> type/release/polarity/identity/topology admission
             -> MatrixTopology -> ExecutionPlan
```

## State, Ownership, and Lifecycle

Compiled topology is an immutable Sendable value. Runtime sparse matrices are exclusively mutated by the analysis.

## Failure, Concurrency, and Constraints

Compilation returns typed CompileError for missing or resolved MOS stage, mismatched identity/type, or invalid topology. Device binding separately validates its receipt against the numerical owner before execution.

## Verification and Change Impact

MOS stage admission tests exercise actual compile success and refusal for legacy/resolved stages, identity/type mismatch, and malformed topology. OSDI topology and Native integration tests inspect actual prepared internal-node entries and numerical execution. Revalidate device binding and analyses when topology changes.

The portable release no longer owns execution admission. Compiler validates
prepared receipt level, identity and topology; NativeMOSDevicePreparer owns
the supported classic releases. External compact models use the distinct OSDI
prepared-instance path; no native BSIM adoption is pending.

## D3 Change Impact

The [D3 resolution owner](../CoreSpiceLowering/DiodeResolution/DESIGN.md) defines occurrence admission, frozen
evaluation and immutable result transport. This layer consumes that contract;
D4 numerical preparation and D5 API/CLI adoption are separate implemented owners
linked by the package design. Its own affected path and tests remain the D3 proof.

## Accurate Newton Residual Kernel

SparseMatrix owns `package checkedResidual(vector:rhs:into:)`, a signed residual
`A*x - rhs` over the original CSR system. Analysis reverses this sign when it
needs a correction right-hand side. Each rounded product `p = a*x` contributes
its FMA error `(-p).addingProduct(a, x)`. Neumaier error-free sum transforms
accumulate both the product and its error; `-rhs` participates before the final
compensated result is rounded. Summation compensation alone cannot recover a
rounded product's error.

The fixed Swift 6.4.0 module interface implements `Double.addProduct` with
`Builtin.int_fma_FPIEEE64`; `addingProduct` delegates to that formal API. Exact
binary regression tests verify its compiled behavior through this kernel.

Vector, RHS, and caller-owned result lengths must equal the matrix dimension.
All input floating values must be finite. Nonfinite operands and overflow in a
product, sum, correction, or final residual throw typed `SparseMatrixError`.
Finite subnormal rounding retains binary64 semantics; the kernel does not claim
an exact rational result for arbitrary ill-conditioned inputs. A thrown call
invalidates the output, whose earlier rows may already have been written.

The kernel borrows its inputs and uses scalar accumulators without allocating a
dimension-sized work vector. The caller owns result storage and its uniqueness;
aliased Array storage may detach under Swift copy-on-write. Work is one input
validation pass and one CSR pass: a conservative envelope is
`40*nonZeroCount + 40*dimension` scalar work units per call.
The public ordinary multiply and LinearSolver contracts remain unchanged.
Analysis owns refinement policy and convergence tolerances; this layer does not
reinterpret a failed residual as convergence.

[Analysis](../CoreSpiceAnalysis/DESIGN.md#bounded-linear-refinement) composes this
kernel with a caller-supplied factorized LinearSolver. Exact binary counterexamples
and independently solved frozen systems verify product and sum roundoff rather
than merely checking structure or coefficient existence. This contract does not
establish transient assembly or physical process qualification.

`Tests/CoreSpiceCompileTests/SparseResidualTests.swift` owns the exact product
cancellation witness, RHS cancellation and signed results, empty rows, shape
failures, nonfinite input failures, and product/accumulator overflow boundaries.

## S3 Prepared OSDI Admission

Status: implemented. OSDI instances require the portable prepared receipt before sparse
construction. Admission checks the exclusive OSDI stage/type, connected terminal prefix,
active-coordinate-derived private node/current counts, inventory membership and
exclusive private ownership. Resolved stages cannot compile. Compilation consumes
inspection evidence only; native binding consumes the separately retained owner.

`CoreSpiceOSDINativeTests` exercises the actual compiler through all 43 qualified
Native DC circuits and directly rejects a resolved-only OSDI circuit before sparse
construction. Its execution record joins every raw model row to the actual
compiled row, including optional trailing terminals and private flow/thermal rows.

## S4 Direct Complex CSR Stamping

ComplexSparseMatrix.addValueDirect mirrors the existing real CSR contract: the binding owner supplies an index checked against the immutable structure, and repeated stamps add directly without a row/column lookup. ComplexMatrixStamper exposes this optional capability; legacy callers continue using row/column stamps. Analysis frequency tests compare direct and ordinary complex entries through the actual solver.

## True Sparse Numerical Composition

The [factorization component](SparseFactorization/DESIGN.md) owns numerical,
storage, control and statistics contracts. The [ordering component](SparseOrdering/DESIGN.md)
owns deterministic structural preparation. Public real/complex solvers are thin
composition entries. Their child designs are the authority; Compile does not
infer factor capacity from a symbolic no-pivot pattern. Old dense/fallback numerical
paths and DynamicSparseRow overflow storage are removed when the new implementation
is verified. LinearSolver/ComplexLinearSolver expose configureExecution as a
requirement, so bounded existential dispatch cannot bypass control.

## Classic MOS and External Compact Models

Classic MOS receipts describe exactly four physical ports and no private nodes or
branches. The compiler checks receipt identity, L1/L2/L3 release, polarity and
port inventory before constructing sparse topology. Removed native level-49/54
type names require explicit OSDI preparation; they cannot pass through generic
stamping or acquire a classic receipt. OSDI private/collapsed/flow/thermal topology
continues to use its separate prepared receipt and alias/ownership admission.

`MOSStageAdmissionTests` covers all classic releases/polarities, mismatched and
unprepared receipts, malformed ports, private-topology refusal, removed native
type names and retained passive compilation. Actual OSDI topology tests own private
node, alias and branch coverage; classic fixtures do not simulate a retired BSIM.
