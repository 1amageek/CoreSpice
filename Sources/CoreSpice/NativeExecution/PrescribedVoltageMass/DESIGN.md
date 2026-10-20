# Prescribed Voltage Mass

## Purpose and Scope

Child of [NativeExecution](../DESIGN.md), with no children. Own source-bound
assembly of reduced mass M=P C A and left/right drift P(F0+C E phiDot) for the
actual prepared circuit. C covers the larger original D; F0 covers the explicit
Values z/U slab. Checked regularity is a sufficient conditional matrix fact,
not existence, roots, DAE index/state count, flow or entire-history authority.
Status: finite conditional implementation qualified by the focused evidence below.

## Responsibilities and Boundaries

Retain the same actual Values, original forest/control and source scopes. Query
each actual OSDI source exactly once on Original D. Native represented charge
coefficients and sealed protocol-2 raw C feed a single sparse assembly. No
functional Q-value-span rank, sampled derivative, op5 AD-root, source-seam
extension, explicit Qt or untrusted matrix certificate is substituted.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Actual inventory and original cumulative control | Other or uncontrolled owners refuse |
| [PrescribedVoltageValues](../PrescribedVoltageValues/DESIGN.md) | depends on | Private retained original D, slab F0, laws and original forest | Slab bounds do not replace Original D |
| [PrescribedVoltageReconstruction](../PrescribedVoltageReconstruction/DESIGN.md) | depends on | Sealed spatial borrow with mandatory Original/Lifted selection | Existing current path keeps Lifted; mass uses Original |
| [PrescribedVoltageReduction](../../../CoreSpiceAnalysis/PrescribedVoltageReduction/DESIGN.md) | depends on | Exact A/P indices and E tangent lift | Forest coordinates are not DAE/state dimension |
| [RangeExecution](../../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | depends on | Actual smooth full raw C and retained source/query scope | Time input and demanded nonsmooth dependencies refuse |
| [ValidatedMatrixRegularity](../../../CoreSpiceAnalysis/ValidatedMatrixRegularity/DESIGN.md) | depends on | Same-control independent sparse norm certificate | Uncertified does not mean singular |
| [Compile](../../../CoreSpiceCompile/DESIGN.md) | depends on | Checked canonical SparseStructure | Uncontrolled triplet builders are not used |

## Architecture

```text
actual prepared owner + immutable Values + explicit limits
    -> original forest row/column reduced map, original source SI slopes
    -> each actual source: one smooth range over ORIGINAL D
    -> same raw coefficient: mass triplet and left/right input-rate contribution
    -> stable bounded sort + outward coalesce + canonical CSR
    -> private retained mass/drift/source owner
    -> optional explicit sparse R -> existing same-control regularity checker
```

## Contracts and Invariants

Package entry `assemblePrescribedVoltageMass(values:range:limits:cancellation:)`
requires the exact original prepared control and checked actual inventory.
The explicit limits bound triplet capacity, retained bytes, native workspace and
precision. No embedded proposal inverse or guessed capacity is supplied.

Every original row has its already-checked `Plan.reducedCoordinate(at:)` index:
all floating electrical component members share a coordinate, untouched axes
retain their own index, and ground-connected/selected-current rows have none.
Thus P=A^T projection maps both rows and columns using entries zero or one.
All retained body, thermal and unselected-flow coordinates remain present.

C is evaluated on the FULL original coordinate/time box, including formal source
current intervals. The shared spatial helper requires an explicit `.original`
choice; the existing reconstruction path explicitly chooses `.lifted`. Source
binding/setup/topology/worker/profile/options and exact query are checked and
retained. Every raw C entry is scanned before ground/alias projection. Both raw
rows and columns sum through actual aliases and instances. Exact zero terms are
charged before skipping. Source-current READ exclusion remains actual structural
authority, not an invented tangent value.

Native exact represented charge coefficients and actual raw C coefficients emit
(row,column,enclosure) mass contributions whenever both reduced indices exist.
A missing A column does NOT discard its drift contribution: E phiDot can be
nonzero for a prescribed grounded-component coordinate. Existing actual source
laws provide distinct left/right SI slopes, delta*normalizedSlope/timeScale.
Only E tangents are lifted with algebraic zero reduced coordinates; no physical
zero zDot or source current is claimed. Drift starts with P times the retained
slab F0 and adds all C E phiDot contributions. Time-dependent/nonsmooth/unsupported
source operations refuse; Qt is not supplied or inferred by this component.

Fixed-capacity triplets preserve every contribution until deterministic stable
(row,column) merge sorting and compensated outward coalescing. Only exactly zero
coalesced enclosures may disappear. Canonical CSR has strictly increasing columns,
unique positions, complete row pointers and separately owned CE values. No dense
global matrix, Set/dictionary, unaccounted sorted copy or repeated directional
source query is used.

The private result retains original Values, CSR/values, two drifts, actual scopes
and leases. `withMatrix` exposes dimension and three nonescaping Spans, not an
escaping copyable CSR that could outlive its lease. Checked indexed drift access
uses the existing left/right Side. The optional regularity operation borrows
explicit R structure/Double values and invokes existing `ValidatedMatrixRegularity`
with the original control. Its checked result retains the mass owner. k=0 has no
fabricated regularity special case: certification throws `emptyMass`. Failed
strict norm certification propagates `uncertified`, not a singularity verdict.

## Runtime Flows

Validate owner/inventory, dimensions and checked capacities before allocation.
Admit native workspace and output leases, compute map/E tangents, consume one
actual source range per device, close it before retaining its scope, sort/coalesce
under checkpoints, build checked CSR and publish only a complete owner. The
regularity operation is synchronous and borrows its immutable input spans.
No span crosses await; source failures retain primary/cleanup/pending owners.

## State, Ownership, and Lifecycle

| State | Owner / isolation | Release |
|---|---|---|
| Actual inventory, Values and source bindings | Original prepared/immutable Values | Final retained owner |
| Work and full live peak | Existing unconditional Mutex preparation control | Original reservation tickets |
| Two triplet buffers, row map, zero/slopes | Operation-local admitted workspace | Operation exit |
| E lifts/reduction workspace | Original reduction owner/admitted leases | Operation exit |
| CSR/drifts/scopes | Private immutable result | Last result/regularity copy |
| R proposal | Caller-owned immutable input | Synchronous borrow end |

Checked accounting includes simultaneous triplets/sort scratch, maps, lower
workspace/two input lifts, projection scratch and CSR/drift retention. Source
helper/inventory admissions remain independently checked by the SAME global
control, including coexistence with all native storage. Every initialized/copied
cell, source product, sort comparison/copy and coalesce step consumes cumulative
work before processing. No budget reset or refunded work exists. Native/WASM/
Embedded common storage introduces no target-specific mutable-state branch,
unsafe pointer or unchecked Sendable. Logical managed payload is not allocator
metadata, process RSS or a zero-allocation claim.

## Failure, Concurrency, and Constraints

Typed failures cover malformed limits/input, wrong owner/binding, missing smooth
capture, checked capacity exhaustion and empty certification. Existing source,
numerical, CSR, regularity, work/storage/cancellation and cleanup causes propagate.
No partial operator/certificate is published. The original prepared circuit and
retained Values remain usable after ordinary refusals; closed underlying model
owners cannot be reopened implicitly.

## Verification and Change Impact

Independent native oracle: floating V(p,n) with C2(p,n)+C3(n,ground) gives M=3
and drift=-3*phiDot when R4(p,n) cancels under P. Distinct slopes verify sides/SI.
Wrong R, empty reduction, checked capacities, sparse representative size and exact
lease/cancel/refund tests own numerical/resource behavior. Actual C+1/C+1 gives
M=2 and R=.5 certifies; C+1/C-1 cancels and must be uncertified. Aliased parabola
checks raw row/column sums. An abs-Q device on free z has a positive small Values
slab but Original D crossing zero: the actual source must refuse nonsmoothness,
not certify from the smaller slab. Existing images/compiler fixtures are reused.
Only the affected existing .17 actual spatial-borrow paths need regression after
factoring; Analysis arithmetic and ordinary point execution remain unchanged.

Qualification evidence: [aggregate-review-r3.json](../../../../.verification/prescribed-voltage-mass-20261020/aggregate-review-r3.json)
binds the fixed Swift 6.4 release/jobs-2 build and focused 10 declarations in
three suites, zero skips: four native tests, three actual OSDI tests (four circuit
variants), and three affected reconstruction tests. The 512-axis case retained
512 CSR entries, consumed 46,692 cumulative assembly/certification work units,
asserted the admitted native workspace below 512 KiB, and refunded final live and
temporary storage to zero. Its observed peak logical managed payload was
21,568,736 bytes including the original preparation floor and Values, not an
allocator or process-memory bound. The
[one scoped review](../../../../.verification/prescribed-voltage-mass-20261020/scoped-review-r1.json)
closed without a concrete finding. This evidence certifies only the stated
Original-D mass, slab drift and sufficient regularity contract.
