# Prescribed Voltage Reduction

## Purpose and Scope

This package-internal component is a child of [Analysis](../DESIGN.md). It owns
the exact incidence-forest reduction of explicitly identified independent ideal
voltage-source edges. It has no children. The Native lower kernel is qualified by
15 owner tests and the457-test Analysis regression suite, with the comprehensive
review closed. This is conditional incidence/enclosure algebra, not source-jet,
physical-chart, root, continuation or history authority.

## Responsibilities and Boundaries

Inputs use actual global matrix indices and a complete, ordered nature axis.
They are explicit assumptions, not evidence that a source is an actual bound
device. The upper consumer must establish device identity, independence of the
remaining F/Q from eliminated source currents, source jets, units and model
provenance before composing a physical claim. A missing contract requires refusal
by that consumer. This component never inspects models, creates jets, selects an
operating domain, solves a chart or certifies physical roots.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | Run numerical/resource ownership | No independent budget |
| [SparseExecution](../SparseExecution/DESIGN.md) | depends on | Existing work/storage/cancellation control | All buffers admitted before initialization |
| [RangeExecution](../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | future consumer | Full original charge/KCL obligation | No current composition or public SDK change |
| [NumericalState](../../CoreSpiceDevices/NumericalState/DESIGN.md) | depends on | Outward compensated enclosure operations | Contains-zero is not equality proof |

## Architecture

```text
explicit full matrix nature axis + ideal-source edges + existing run owners
    -> checked deterministic rooted forest
    -> immutable sparse A/E/P/K tables and original-index mappings
    -> reusable operation-local workspace
    -> outward lifted coordinates / reduced residual / all original residuals
    -> upper proof obligations (not discharged here)
```

## Contracts and Invariants

An axis entry is electrical potential, electrical flow, or thermal potential in
the existing DCEquationKind contract. Only electrical-potential endpoints and
explicitly selected electrical-flow source rows participate in the forest.
Every other row, including body, internal flow, thermal and unselected branch
rows, remains represented. Ground is an explicit absent endpoint, never an
inferred matrix row. Source rows must be distinct and owned exactly once in the
explicit input. Self loops and every cycle, including parallel equal sources,
are typed refusals; consistent voltages do not make cycle currents unique.

Let G be the oriented source incidence on all rows except the selected source
constraint rows. Each source has +1 at its positive endpoint and -1 at its
negative endpoint. Forest roots are ground where present, otherwise the smallest
original matrix index. In source input order, the sparse tables represent

    p = A z + E u,    G^T A = 0,    G^T E = I,
    P = A^T,         P G = 0,      K G = I.

Untouched non-electrical rows have identity A/P entries. A floating component
retains its root supernode KCL. A grounded component has no artificial ground KCL
equation. Parent links encode E as signed source-path sums; postorder subtree
sums encode K. There is no dense matrix, numerical rank or sampled proof.
Preparation independently checks parent edges, source uniqueness, root choice,
coordinate coverage and traversal ordering before returning a plan.

The caller supplies full-axis enclosures for static F0 and separately named
state charge rate, prescribed-input charge rate Qu*u', and explicit-time charge
rate Qt. They must be zero on selected source constraint rows because those rows
are synthesized from the explicit source equations. No derivative is inferred
from a sampled waveform or a companion residual. The application forms r as the
sum of those four contributions, reduces P*r, and reconstructs iV=-K*r. It then
returns every original residual, adding G*iV at endpoints and vpos-vneg-u on
each selected constraint row. Source currents use the original positive-to-
negative orientation. This is conditional outward arithmetic only.

In particular, an interval containing zero does not prove P*r=0, original KCL,
existence or uniqueness. Nonzero and unresolved residual obligations are returned
without a successful physical-certificate flag. The upper owner must prove the
reduced equations, nondependence and source/model authority separately. A C in
parallel with V has no remaining coordinate but still reconstructs iV=-C*u'.

### Value-Only Affine Lift

The package `lift(workspace:reducedCoordinates:sourceValues:)` operation exposes
only the pre-current-reconstruction affine coordinates. Its private Lift result
retains the same plan/control and admitted immutable values. Selected current
rows are explicitly unavailable to `coordinate(at:)` (typed invalidInput), while
all retained electrical/internal-flow/thermal rows follow the same source-path
loop used by apply. No invented F or charge-rate arrays are accepted. Native
preserves original-domain current intervals separately. The existing apply path
shares that exact affine loop and retains its original initialization, arithmetic,
checkpoint order and reconstruction behavior.

### Additional Per-Call Cancellation for the Affine Lift

The new Native voltage-observation consumer accepts a per-call cancellation
token independently of the preparation token retained by the original mandatory
control. The additive package overloads are
`makeWorkspace(plan:cancellation: CancellationToken)` and
`lift(workspace:reducedCoordinates:sourceValues:cancellation: CancellationToken)`.
They keep the same Plan, original control and cumulative work/storage ledger.
They do not construct another controller, budget, owner or mutable token cache.
Only the new path checks the additional token, raising the existing
`AnalysisError.cancelled` without publishing a partial Workspace or Lift.

Required token checkpoints precede validation and work, follow every reservation
before allocation/initialization, follow the original initialization work charge,
and bracket the existing bounded Work ticks used by zero/fill, affine forest
traversal and result copy. A control checkpoint can itself call an external
accountant that cancels the new token; recheck before executing the next unit.
A cancellation at workspace admission must not proceed to initialize its 3n
buffers or reserve the later n-element Lift. A cancellation at a work checkpoint
must not use its prepaid credit to continue traversal or reserve a result.
Already charged work stays spent; all released storage reservations refund.
Old overloads retain their original validation/checkpoint order, arithmetic,
byte/count formulas, initialization and owner behavior. The new token is a
synchronous operation-local input, not retained by a Plan, Workspace or Lift.

The owning Native observation test constructs the actual original owner with
live token A, then deterministically cancels distinct token B from the inner
workspace-reservation callback and the bounded forest-work callback. It checks
no later Lift reservation/charged work, no partial publication, exact storage
refund and reuse of the original live owner. The actual red recorded one extra
Lift reservation in both cases and 272/4 work units after cancellation; typed
cancellation, refund and reuse otherwise held. Both unchanged cases now pass
with three reservations and zero later reservations/work. The Native observation
suites passed ten declarations/thirteen cases and the affected old Root/Chart/
Flow subset passed twenty-seven declarations/twenty-nine cases, all with zero
skips. The [single observation review and finding-limited recheck](../../../.verification/prescribed-voltage-flow-observations-20261020/review-r7.json)
are closed without remaining findings. The old nil-token arithmetic,
reservation/charge quantities and order, array initialization and traversal
statements remain source-equivalent after removing the explicit token checks;
no whole Analysis rerun is claimed for this additive cancellation path.

## State, Ownership, and Lifecycle

The kernel holds one immutable reference to the mandatory existing
`LinearSolverExecutionControlling` owner. The controlled constructor borrows the
caller's cumulative work, cancellation and storage contract without creating or
resetting a budget. The original constructor constructs the same
`AnalysisLinearSolverControl` adapter from its budget, storage accountant and
cancellation token, then delegates with unchanged limit validation and initial
zero-work cancellation checkpoint. Plans retain that owner and admitted
immutable arrays; copies and indexed views retain their plan. A workspace is
non-Sendable, synchronous and operation-local, reusable by its isolated caller.
It cannot be used with another plan or resource owner. No unsafe storage, pointer
escape, global cache, foreign code or independent quota is introduced.

Storage checks use checked Int arithmetic, explicit workspace/result ceilings,
and caller leases before any Array initialization. Preparation temporarily
coexists with immutable result tables; application scratch coexists with copied
output tables. Every initialized/copied element is charged before allocation.
Bounded operation batches checkpoint work and cancellation before processing;
no post-hoc charges, refunded work or hidden reset is permitted. Storage leases
release on every throw and on final result/workspace release. Input arrays remain
caller-owned and are borrowed during synchronous operations.

## Failure, Concurrency, and Constraints

Invalid nature/index/shape/limit inputs, duplicate source rows, self loops, cycles,
wrong-owner plans/workspaces, capacity overflow and workspace/result ceilings are
typed failures. Numerical enclosure failures and existing work/storage/cancel
failures propagate. No partial plan or application is published. Calls have no
await or callback into model code. A workspace is not a shared mutable owner.

## Verification and Change Impact

[PrescribedVoltageReductionTests](../../../Tests/CoreSpiceAnalysisTests/PrescribedVoltageReductionTests.swift)
owns exact small-integer A/E/P/K identities, deterministic roots/permutations,
nonconstant given-jet C-parallel-V signs and full KCL, floating imbalance,
untouched electrical/internal-flow/thermal axes, cycles and malformed indices,
checked capacity arithmetic, mandatory cumulative work, cancellation, failure
refunds and copied output lifetimes. Qualification does not extend those finite
tests into a physical-chart or source-jet theorem. A later actual-device/OSDI
consumer must establish and test its additional assumptions independently.

[PrescribedVoltageControlTests](../../../Tests/CoreSpiceAnalysisTests/PrescribedVoltageControlTests.swift)
owns direct mandatory-control injection: pre-spent cumulative work across two
reductions, unchanged checkpoint/storage failure propagation, and original
control/lease retention through copied plans and applications. This additive
constructor changes neither forest arithmetic nor admission quantities/order.
