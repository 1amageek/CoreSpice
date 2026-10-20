# Prescribed Voltage Chart

## Purpose and Scope

Child of [NativeExecution](../DESIGN.md), with no children. Own a source-bound,
conditional coordinate-algebraic charge chart on one prescribed-source Values
slab, and the same-owner initial coordinate chart specified below. The profile uses proposed algebraic reduced row selectors B and the
canonical complementary selectors L; it does not require a complete global
functional-Q kernel, dense completion, charge anchors or full mass regularity.
Status: finite conditional implementation behaviorally qualified; the one scoped review and its P1 recheck are closed.
The initial coordinate chart is behaviorally qualified on the finite cases below;
its one scoped review is closed without findings. It does not grant initial-set
coverage.

## Responsibilities and Boundaries

Check the strong identity B P Q=0 on the larger original D against actual native
charge coefficients and actual full-domain source identities. Assemble
H=(L P Q-q, B P F0) and its reduced-coordinate Jacobian
J=(L P C A; B P G A), then invoke the independently checked lower parametric
root operation with the original control. Only a successful checked root result
may publish a chart. No root search, continuation, full chart cover, source
current reconstruction, flow, entire history, Qt, seam extension or DAE/state
rank is owned here. Source identities, smooth derivative authority and lower
root inclusion are distinct prerequisites, not interchangeable receipts.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Actual prepared inventory, source bindings and cumulative control | Other or uncontrolled owners refuse |
| [PrescribedVoltageValues](../PrescribedVoltageValues/DESIGN.md) | depends on | Original D, z slab, retained source laws, F0/Q assembly and forest | Lifted source identities do not prove original-D identities |
| [GlobalChargeKernel](../GlobalChargeKernel/DESIGN.md) | coordinates with | Factored private full-domain source-row membership import | No dense global completion or anchor/rank path is called |
| [PrescribedVoltageReconstruction](../PrescribedVoltageReconstruction/DESIGN.md) | depends on | Sealed explicit-original smooth spatial borrow | No explicit time input or nonsmooth acceptance |
| [PrescribedVoltageMass](../PrescribedVoltageMass/DESIGN.md) | depends on | Bounded triplet stable sort/outward coalescer | Reuse implementation without changing its numerical order |
| [ExactRowAlgebra](../../../CoreSpiceAnalysis/ExactRowAlgebra/DESIGN.md) | depends on | Exact dyadic local-row membership | Incomplete local bases cause refusal, never a guessed zero |
| [ValidatedParametricRoot](../../../CoreSpiceAnalysis/ValidatedParametricRoot/DESIGN.md) | depends on | Same-control parametric inclusion and uniqueness | Lower API and DESIGN must be fixed before implementation |

## Architecture

```text
actual prepared owner + Values + explicit B/q/center/Y/limits
    -> checked B/complement L permutation and original forest maps
    -> native exact B P Q sum + each actual source original-D local membership
    -> one original-D smooth G/C query per source -> sparse J
    -> same-owner Values assembly at exact center z, full phi/time parameter box
    -> H(center; q,phi,time), z box, J, explicit Y
    -> independent same-control parametric root checker
    -> private retained conditional chart owner

same owner + initial-time Values + explicit B/d0/center/Y/limits
    -> the same strong-null-Q and original-D smooth-source checks
    -> Hinit=(z_L-d0, B P F0), Jinit=(I_L; B P G A)
    -> same-control parametric root checker on checked initial Z
    -> actual full-Q query on that checked Z and the SAME initial source conditions
    -> q0=L P Q enclosure + private retained conditional initial-root owner
```

## Contracts and Invariants

The package-only prepared-owner entry is:

```swift
package borrowing func certifyPrescribedVoltageChart(
    values: NativePrescribedVoltageValues,
    algebraicRows: [Int],
    chargeParameters: [CompensatedEnclosure],
    center: [CompensatedValue],
    inverse: SparseStructure,
    inverseValues: [Double],
    capture: OSDIConstitutiveCaptureInputs?,
    range: OSDISmoothRangeCaptureInputs?,
    limits: NativePrescribedVoltageChartLimits,
    cancellation: CancellationToken
) async throws -> NativePrescribedVoltageChart
```

Arrays at the asynchronous entry have immutable owners; no Span crosses await.
`NativePrescribedVoltageChartLimits` owns explicit maximumTriplets,
maximumRetainedBytes, maximumWorkspaceBytes, precisionBits, values
(NativePrescribedVoltageLimits), exact (ExactRowAlgebra.Limits) and root
(ValidatedParametricRoot.Limits). No quota, inverse, center or row choice is
inferred. The lower call borrows the admitted arrays synchronously. The fixed lower API is:

```swift
ValidatedParametricRoot.certify(
    lower: lower.span, upper: upper.span, center: center.span,
    centerResidual: centerResidual.span,
    jacobian: jacobian, jacobianValues: jacobianValues.span,
    preconditioner: inverse, preconditionerValues: inverseValues.span,
    limits: limits.root, control: originalControl)
```

Root limits explicitly bound maximumDimension, maximumJacobianNonzeros,
maximumPreconditionerNonzeros, maximumWorkspaceBytes and maximumResultBytes.
The immutable lower result retains its own admitted image/lease and exposes
`dimension`, `normUpperBound`, and `image(at:)`. It validates nonempty strict
represented endpoint boxes, center membership, canonical J/Y, strict q<1 and
strict Krawczyk inclusion. Native provides exact source/domain construction and
C1 premises, never caller-asserted derivatives. An empty reduced chart refuses;
it does not fabricate the lower check.

Let k be the original Values forest's reduced count. B must be increasing,
unique and in 0..<k; L is the increasing complement. H/J rows are ordered L then
B, and reduced coordinate columns retain their original order. The checked
[B;L] selector matrix is a permutation; no density or numerical rank test is
needed. The q box has |L| entries, center has k represented entries, and center
must lie in the retained z box. The exact lower/upper endpoint arrays used by the lower checker define the
checked root Z. They are fixed early from the Values proposal, enclosed outward
as CE coordinates, and lifted with the original retained reduction/plan/phi.
Before any source query, every nonselected-current coordinate of that entire
lift must be contained in original D. Original selected-current D intervals stay
formal evaluation sections; structural READ exclusion remains mandatory. Native
workspace accounting includes this endpoint enclosure, reduction workspace and
expanded lift, with their phase scopes released before source queries. The SAME
endpoint arrays are passed to the lower checker and retained in the private
payload; future consumers must use checked Z, not silently substitute the
original CE proposal. The center is fixed only in z: source phi/U and
time retain their complete original Values parameter box. Center H is generated
internally with existing Values assembly, using the same prepared owner,
original D, original selected source descriptions, conditions and source
capabilities. Caller-supplied H/J or decoded proof objects are not accepted.

The strong null identity uses lambda(global)=1 exactly when the actual forest
reducedCoordinate(global) equals a selected B row. Raw ground has lambda=0;
aliased raw rows retain their actual repeated lambda. Native represented charge
terms are coalesced by selected reduced row and original global column. An
exact-zero outward enclosure proves the represented sum is zero; any uncertain
nonzero-width remainder refuses, without claiming the true sum is nonzero.
Each source's local raw query is checked against its actual full-original-D
reactive identity basis. Only source-touched B selectors require local query
vectors; the identically zero pullback is an exact trivial relation. Retain the
source binding, complete original query/context and exact local proof. This is a
sufficient sourcewise identity proof, not a universally successful algorithm for
cross-instance cancellation. Global dense N/completion/anchor arrays are absent.

Every actual source receives one smooth G/C query over the larger original D,
not the smaller lifted slab. Its actual program/setup/topology/worker/profile/
options and the original-D query must match the identity source. Raw rows and
columns, including ground and all aliases/body/thermal/flow axes, are scanned
before projection. C contributes L P C A; G contributes B P G A. Native exact
linear terms feed the corresponding rows. On this admitted smooth domain,
B P Q=0 implies B P C=0, so algebraic H is B P F0 and requires no input-rate or
Hessian term. Explicit Qt/time input and source nonsmoothness still refuse.

The same query also bounds the dynamic static derivative K=L P G A without
retaining another matrix or opening another helper. One temporary Double sum per
dynamic row accumulates outward absolute contributions of every native static
term and every raw G entry whose actual row projects to L and whose actual column
has a free reduced coordinate. Ground and selected-current columns have no A
component. Repeated raw row/column aliases are visited before absolute summation;
their cancellation may inflate the result but cannot invalidate this triangle
inequality bound. The maximum row sum Kbar therefore bounds ||L P G A||inf on
the exact original D, using the same coordinate units and ordering as J.

Only Kbar is retained in the private spatial payload and existing chart lease.
Its temporary |L| Double cells and Array header join the checked simultaneous
workspace before allocation; initialization, every inspected contribution,
directed sum and final maximum scan consume the original cumulative control.
Nonfinite/overflow refuses rather than publishing infinity or dropping a term.
Exact zero contributions leave zero unchanged; positive underflow remains
positive. The source scopes, full query/context, native laws and actual forest
already retained by the chart remain the authority for this scalar. A copied
scalar alone is not a source or physical certificate.

The lower root checker must independently validate the sparse J/Y and all box,
center and residual inputs under the SAME original control. Its strict interior
inclusion and uniqueness fact is conditional on the actual H/J construction and
full-domain smoothness supplied here. A private result retains Values, center
Values, original D, row selection/complement, q/center/Y, source identity proofs,
smooth scopes, lower root result and all leases. Arbitrary public records cannot
construct successful chart authority. Indexed values or synchronous borrowed
views may inspect the result; no executable claim is made by construction alone.

### Same-Owner Initial Coordinate Chart

This additional package operation does not change the existing charge-chart
equations, limits or numerical profile. It supplies the initial root and actual
charge enclosure needed by a later source-family/slab composition. It owns no
public preparation API, Timing interpretation, source-family membership, search,
initial-set cover, steady-state assumption or history claim.

The proposed entry follows the existing prepared-owner argument style rather
than adding a request facade:

```swift
package borrowing func certifyPrescribedVoltageInitialRoot(
    values: NativePrescribedVoltageValues,
    algebraicRows: [Int],
    dynamicInitialCoordinates: [CompensatedEnclosure],
    center: [CompensatedValue],
    inverse: SparseStructure,
    inverseValues: [Double],
    capture: OSDIConstitutiveCaptureInputs?,
    range: OSDISmoothRangeCaptureInputs?,
    limits: NativePrescribedVoltageChartLimits,
    cancellation: CancellationToken
) async throws -> NativePrescribedVoltageInitialRoot
```

`values` must belong to the actual prepared control and contain one exact
represented SI initial time: the lower and upper context time pairs have equal
high/low bit patterns.
All other context fields and actual program/setup/topology, worker, profile,
options and source laws retain the existing identity/smooth query rules. The
source U intervals are explicit initial-time assumptions. They do not acquire
a common-function or earlier-history meaning here. Any later consumer must
join them to its actual source family. Missing controlled snapshots, explicit
source time input and nonsmooth original domains retain their existing refusals.

For the existing forest reduced order of size k>0, B is the same checked sorted
strong-null-charge row selection and L its canonical increasing complement.
The `dynamicInitialCoordinates` box d0 has |L| entries in that L order. It is an
explicit initial-coordinate premise, not a numerical estimate of charge or an
assertion that it covers every reachable initial state. It may be a parameter
box. No q0 input, implicit DC solve, initial plateau or quiescence is accepted.
The initial candidate Z, center and sparse Y are untrusted numerical proposals.

The square system is

```text
Hinit(z;d0,phi0) = (z_L-d0, B P F0(Az+E phi0))
Jinit            = (I_L; B P G A)
```

The first |L| rows are exact coordinate selectors, including exact center
residual zcenter_L-d0. The final |B| rows use actual full-row F0 and its
same-source original-D G derivative, with no caller H/J or point-rank authority.
The strong B P Q=0 premise is still independently checked against every actual
native term and every touched raw source row. All raw aliases, ground reactions,
body, thermal and flow axes keep the existing projection rules before row
selection. Actual source identity, derivative and nonlinear-root checks remain
separate obligations. The existing source-identity, smooth spatial borrow,
triplet, Values and lower parametric-root implementations are reused; no model
equation, source oracle or general root-search implementation is introduced.

The initial Z endpoints are produced and expanded exactly as for the charge
chart. The entire expanded affine lift, not only its center, must be contained
in original D before source evaluation. The same endpoint arrays define the
lower root check, reconstruction and retained initial scope. Center evaluation
fixes only z: d0, phi0 and other retained source conditions remain complete
parameter boxes. Successful strict inclusion and contraction imply one initial
algebraic state for every parameter tuple in those stated premises; they do not
prove that all such tuples are physical histories.

After root success, a fresh existing Values assembly evaluates complete actual
F0/Q on the checked initial Z endpoints, the SAME phi0/source descriptions and
the SAME exact initial context. It must not reuse Q from the narrower original
CE proposal or query another time, source, prepared owner or profile. This box
contains every checked initial root; its Q query may conservatively include
non-root points. The result computes q0=L P Q from the actual forest row
projection, summing every original row contribution. q0 is explicitly an outer
enclosure, not an exact range or a new independent parameter. No inverse-Q
reconstruction, caller charge, copied native cache or zero replacement is used.

`NativePrescribedVoltageInitialRoot` is a package final immutable class
with a private initializer. It exposes dimension, charge/algebraic coordinate
counts, scalar `image(at:)`, `initialCharge(at:)`, `chargeReducedRow(at:)` and
`algebraicReducedRow(at:)` accessors. Its private payload retains initial Values,
center Values, checked-Q Values, d0, B/L, exact checked endpoints, center/Y,
actual identities/smooth scopes, the lower root result and all leases. A narrow
internal same-record/control gate is available to the later Native composition;
no public constructor, mutable device view or detached scalar certifies a root.
The result supplies no selected source currents or evolution authority.

All phases use the original preparation control and existing explicit chart,
Values, exact-row and root ceilings. The initial selector/maps, exact query
integers, initialized CSR/identity rows, center residual, endpoint reconstruction,
source-query scratch and retained arrays are admitted before allocation. The
original input Values, center Values, root image, checked-Q Values and their
leases coexist until publication and must all fit; storage is not counted as
released merely because one phase finished. Helper spans never cross await.
Work remains cumulative and nonrefundable. Failure publishes no partial initial
root; existing source cleanup and cleanupPending ownership preserve primary and
secondary failures. A copied result retains its original control and leases to
the final copy. Ordinary analysis and the qualified charge-chart path are not
rerouted through this new operation.

## Runtime Flows

Validate owner, dimensions, selector permutation, parameters, cancellation and
checked capacities before allocation. Admit all native retained/scratch buffers,
query original-D identities, query original-D smooth derivatives, assemble J,
generate center Values, then call the lower checker. Close each source helper
before retaining its checked scope. Publish only after all phases succeed.
Partial source/root failure preserves cleanup causes and pending cleanup owners.

## State, Ownership, and Lifecycle

| State | Owner / isolation | Release |
|---|---|---|
| Actual preparation, source laws and original forest | Immutable original Values | Last chart/Values owner |
| Cumulative work/storage/cancellation | Existing unconditional Mutex preparation control | Existing reservation tickets |
| Selector maps, source-local queries and triplet scratch | Operation-local admitted arrays | Operation exit |
| J/H/center/Y and exact proofs | Private immutable chart/result payload | Last chart owner |
| Source helper and source spans | Exclusive helper and synchronous callback | Checked close; no Span across await |

Retained and simultaneous workspace accounting includes selector/complement maps,
exact local bases/query integers, two triplet buffers, CSR, H0, center Values,
original/source scopes and lower checker buffers. Checked overflow and admission
precede allocation; exact arithmetic, source scans, comparisons, copies,
coalescing and lower arithmetic all consume original cumulative work. No new
control, reset, refunded work, unbounded sorted copy, dictionary hot path,
unchecked pointer or platform-specific synchronization branch is introduced.

## Failure, Concurrency, and Constraints

Malformed or duplicate selectors, wrong owner/source/query/context, invalid q or
center, unsupported native laws, missing source capabilities, unproved null row,
source nonsmoothness/time input, capacity/overflow, cancellation and lower root
refusals remain explicit failures. Uncertified root inclusion is not a
nonexistence claim. A failed admission publishes no partial chart and refunds
only its own reservations. Existing ordinary simulation and qualified Values,
Mass and Reconstruction numerical paths remain unchanged.

## Verification and Change Impact

The initial operation has dedicated focused qualification: its nine new test
declarations (ten cases) and the nine existing charge-chart declarations passed
together: eighteen declarations, nineteen cases, four suites and no skips. The
fixed Swift 6.4 release/jobs-2 product build took 205.546 seconds; the bounded
runtime command took 8.584 seconds (test engine 2.256 seconds). Its one scoped
review is closed with no concrete findings. Existing charge-chart behavior and
helper/fixture source bytes were unchanged. The dedicated suites exercise:

- C2(d,0), R4(x,p), V(p,0)=phi0: initial equations are d-d0 and
  (x-phi0)/4, Jinit=diag(1,1/4). The root must include d=d0, x=phi0,
  and the actual projected charge must include 2*d0. Two different initial d0
  boxes at the same phi0 must produce their corresponding charges; an isolated
  capacitor must not be initialized by an invented DC or zero-charge rule.
- The existing SDK linear and global-charge-parabola fixtures exercise real
  controlled preparation, original-D identity/smooth queries, aliases/ground,
  checked initial Z and the final actual Q query. Nonlinear charge must retain
  its actual source expression, not a linear-capacitance substitute. Existing
  fixture source/program/profile bytes and explicit conditions remain unchanged.
- Broad initial source U and d0 parameter cells, reversed B/L/order, changed
  actual capacitance, wrong owner, mismatched time pairs and source/profile/query
  bindings, missing capability, original-D seams, singular Y and failed strict
  root inclusion must refuse without a partial result.
- Pre-spent same-control work, allocation refusal at coexisting phases,
  pre-cancellation and cancellation during genuine helper startup, failed helper
  close, pending cleanup retry, copied-result lifetime and final lease refunds
  remain observable without resetting a budget between phases or instances.

Evidence is retained in
[the initial-root qualification aggregate](../../../../.verification/prescribed-voltage-initial-root-20261020/aggregate-review-r1.json)
and [the single scoped review](../../../../.verification/prescribed-voltage-initial-root-20261020/delta-review-r1.json).
This is development owner qualification using clean exact public-revision
checkouts and the recorded pre-existing availability mirrors; it is not a fresh
canonical public release graph. The qualifications do not close source-family
membership, complete initial-set/root cover, all-corner or all-history proof.

Decisive native circuit: C2(d,ground), R4(x,p), prescribed V(p,ground)=phi.
The reduced mass is singular, while B selects x and L selects d:
H=(2d-q,(x-phi)/4), J=diag(2,.25), root d=q/2,x=phi. Parameter boxes with roots
strictly inside the z box must certify. Choosing d as algebraic must refuse its
nonzero Q; a q box driving d outside the z box must refuse lower inclusion.

Actual-source tests own a mixed capacitive/algebraic same-image setup, aliased
rows/ground, a changed capacitance that invalidates B P Q despite a plausible
point proposal, and an abs source whose positive center is smooth but original
D crosses a seam. Owner/domain/source mismatches, quota/cancel, failed cleanup,
retry and final result lifetime/refund require actual typed assertions. Small
source-local membership and sparse CSR checks must not use global dense
completion or functional-Q-span rank. Reusing the bounded coalescer or factoring
the shared domain-identity phase requires one affected existing path regression,
not a repeat whole-owner review. One scoped comprehensive review closes this
snapshot, with one necessary finding-limited recheck if a concrete defect exists.

The q-Lipschitz extension requires a same-Q/J/Y actual source witness whose
dynamic conductance changes: NQ G0 to G0.5 leaves the mixed charge chart unchanged
but changes the conservative Kbar from 2 to 2.5: the p input column has no A
component. Raw aliases may enlarge the bound;
tests must not demand cancellation before absolute summation. Ground and formal
selected-current columns must not add derivative components. These checks pass
in the finite extension qualification linked by the Evolution owner; unchanged
lower chart evidence remains valid only under its original assumptions.

The P1 cancellation regression uses a floating source phi=-1e10 and free
z=center(1e10) +/- 1. Original Values admits the dependent axis near +/-1, but
outward root Z expands the floating lift. Tight dependent D admits Values and
must refuse chart admission; a padded D with the identical circuit, proposal,
center/q/Y and source parameters must certify. This checks the actual affine
domain join, not a tolerance or a changed lower theorem.

Qualification evidence is bound by
[aggregate-review-p1-r5.json](../../../../.verification/prescribed-voltage-chart-20261020/aggregate-review-p1-r5.json).
Native coverage is 24 unique declarations with zero skips: new native five,
actual OSDI four, and unchanged affected GlobalChargeKernel fifteen. The lower
checker evidence covers 29 declarations (30 executions), zero skips. The
[one comprehensive review](../../../../.verification/prescribed-voltage-chart-20261020/scoped-review-r1.json)
found the outward-Z domain join P1, and its
[one finding-limited recheck](../../../../.verification/prescribed-voltage-chart-20261020/finding-recheck-r1.json)
closed without another finding. Preserved reviewed source and actual red show
the old erroneous publication; the fixed tight-D refusal and identical padded-D
success passed alongside all nine new native/actual tests. These are conditional
checked-Z chart facts only, without source-current, flow or history authority.

The [Evolution](../PrescribedVoltageEvolution/DESIGN.md) consumer requires a
mandatory fused immutable cache from this SAME full-original-D smooth query:
full original-row F0, each source-local raw C matrix, left/right full-row CE and
GE input actions, actual SI slopes, and the SAME already-recontained expanded-Z
CE coordinates. Their payloads are admitted under this chart's retained ceiling;
transient input lifts and simultaneous source projection use its workspace
ceiling and original cumulative control. No second model query or old Values.f
substitution is allowed. Chart qualification itself still makes no full-current
section promise; Evolution applies the original forest and may additionally
refuse any reconstructed-coordinate interval outside original D. The internal
Evolution payload gate checks the original concrete preparation control identity.

The fused-cache/checked-coordinate retention change is behaviorally qualified by
the affected native-five/actual-four tests in the
[Evolution qualification](../PrescribedVoltageEvolution/DESIGN.md#verification-and-change-impact).
The original conditional Chart authority remains unchanged.
