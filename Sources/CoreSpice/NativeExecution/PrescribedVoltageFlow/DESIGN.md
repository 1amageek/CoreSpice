# Prescribed Voltage Flow

## Purpose and Scope

Child of [NativeExecution](../DESIGN.md), with no children. Own one finite,
source-bound conditional charge-flow operation on an actual exclusively prepared
Native circuit. Compose the existing initial-root, coordinate-algebraic charge
chart, evolution and Picard checks; do not implement another solver or source
family. The finite conditional profile is implemented and behaviorally qualified;
its one scoped review is closed without remaining findings.

The public result is a conditional numerical result. It neither certifies that
the supplied source enclosures describe a nonempty common function family nor
binds a Physical candidate to the circuit. Complete initial-set coverage,
continuation between slabs, all-root/chart coverage and all-history/corner
composition remain separate obligations.

## Responsibilities and Boundaries

Own actual circuit/source association, internal construction of the initial and
window queries, the initial-root/window-chart branch join, cumulative admission,
conditional Picard composition, immutable inspection and causal failure/cleanup.
The caller proposes finite domains, selectors and numerical preconditioners; it
cannot supply H, J, q0, a vector field, a Lipschitz constant, a proof object or an
evaluation callback.

Timing remains the canonical normalized-function-family owner. Physical must
check its actual Timing joint slice against the result's retained assumptions
and independently establish candidate-to-circuit/rail correspondence. No Core
dependency on Timing, PDK or Physical is introduced. Caller annotations, instance
names alone, Bool rails and a conditional Native result cannot establish that
correspondence.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Controlled preparation and actual exclusive device owner | Ordinary uncontrolled preparation refuses this operation |
| [PrescribedVoltageValues](../PrescribedVoltageValues/DESIGN.md) | depends on | Original domain, actual F0/Q, checked source laws and forest | Source interval data are conditional assumptions, not common-function evidence |
| [PrescribedVoltageChart](../PrescribedVoltageChart/DESIGN.md) | depends on | Actual initial root/Q and uniform implicit window chart | Initial and window time queries are different and must be joined explicitly |
| [PrescribedVoltageEvolution](../PrescribedVoltageEvolution/DESIGN.md) | depends on | Same-chart charge field, rates/currents and charge-state Lipschitz bound | The public AC derivative bound has an almost-everywhere meaning |
| [ValidatedTransient](../../../CoreSpiceAnalysis/ValidatedTransient/DESIGN.md) | depends on | Conditional finite Picard self-map/contraction | This owner must supply all field/source/chart premises |
| [RangeExecution](../../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | depends on | Concrete controlled snapshot/evaluation policies, exact source binding and retryable cleanup | Arbitrary public evaluators/preparers are not proof authority |

## Architecture

```text
public controlled Native preparation + finite request + concrete source policies
    -> actual source/device/axis association and shared-control admission
    -> same spatial original D, exact initial time t0, initial U0/d0/Z0/Y0
    -> initial-root success -> actual whole checked-Z0 Q -> outer q0
    -> same spatial D, outward time window, U/AE derivative, Q/Z/Y
    -> original-domain strong B P Q=0 + uniform implicit charge chart
    -> full checked-Z0 / U0 containment and same-source branch join
    -> matched evolution -> internally derived F and charge-state L
    -> Picard(q0, F, Q, h, L) on the SAME request control
    -> private-init retained conditional result + borrowed actual scope

Timing joint-family slice + actual candidate/circuit/rail producer
    -> future Physical seal of the retained Native assumptions
```

## Contracts and Invariants

### Public operation and finite input values

The public entry extends the existing exclusive owner, without a new facade:

```swift
public borrowing func certifyPrescribedVoltageFlow(
    request: NativePrescribedVoltageFlowRequest,
    capture: OSDIConstitutiveCaptureInputs?,
    range: OSDISmoothRangeCaptureInputs?,
    limits: NativePrescribedVoltageFlowLimits,
    cancellation: CancellationToken
) async throws(NativePrescribedVoltageFlowFailure) -> NativePrescribedVoltageFlow
```

Existing CoreOSDI input VALUES gain public initializers accepting the concrete
`OSDINativePrecisionSessionPreparer`; constitutive evaluation uses the fixed
`OSDINativePrecisionEvaluator` and smooth evaluation is already sealed. Their
arbitrary preparer/evaluator initializers remain package-only trusted test seams. The actual capture/range
execution helpers, root/chart/evolution types and preparation control remain
package/internal. No public protocol callback can manufacture a checked result.

All request values have public value initializers and grant no authority:

| Value | Complete fields and meaning |
|---|---|
| `NativePrescribedVoltageFlowRootProposal` | `coordinates: [CompensatedEnclosure]`, `center: [CompensatedValue]`, `inverse: SparseStructure`, `inverseValues: [Double]`; original reduced-coordinate order, untrusted Z/center/Y |
| `NativePrescribedVoltageFlowSource` | `deviceIndex: Int`, `zeroVoltage`, `oneVoltage`, `timeOrigin`, `timeScale: Double`, `initialNormalized`, `normalized`, `normalizedDerivativePerSecond: ClosedRange<Double>`; one selected actual source and its conditional initial/window assumptions |
| `NativePrescribedVoltageFlowRequest` | `originalLower`, `originalUpper: [CompensatedValue]`, `startTime`, `duration: CompensatedValue`, `sources: [NativePrescribedVoltageFlowSource]`, `algebraicRows: [Int]`, `dynamicInitialCoordinates: [CompensatedEnclosure]`, `initial: NativePrescribedVoltageFlowRootProposal`, `chargeBox: [CompensatedEnclosure]`, `window: NativePrescribedVoltageFlowRootProposal` |

Source order is increasing actual device index; duplicate or unbound sources
refuse. The actual selected source fact supplies signed endpoints and its global
branch, rather than a caller-provided incidence. The two rail values and affine
normalization are explicit conditional value laws attached to that actual source.
All finite/range/shape, axis/nature, read-support and write-support checks of the
existing Values path apply. Unsupported devices and source-current dependence
remain refusals.

`startTime` is exact represented SI seconds and `duration` is exact represented
positive SI seconds. One spatial original domain is supplied. Native derives
the exact initial context pair `(t0,t0)` and a conservative context window
covering every exact `t0+tau`, `0 <= tau <= h`, using compensated outward
arithmetic. A rounded end time is never asserted to equal the exact sum. The
actual initial and window contexts, including any outward endpoint expansion,
are retained for upper comparison. Mode is the existing transient profile;
explicit model time input remains unsupported, without a new Qt assumption.

### Almost-everywhere input semantics

`normalizedDerivativePerSecond` bounds dU/dt in SI seconds almost everywhere.
The conditional function premise is: each actual prescribed U is absolutely
continuous on the retained window, takes its initial value in
`initialNormalized`, stays in `normalized`, and has its almost-everywhere
derivative in that bound. Shared family parameters/correlations and nonemptiness
are not inferred from these interval projections.

Require `initialNormalized` contained in `normalized`. Convert the one public
SI derivative bound outward to the existing bound-law normalized-time units
using the same positive `timeScale`. Feed that SAME bound to both existing
internal side slots. This is a numerical use of the existing reconstruction,
not a claim that every AC member has either one-sided derivative everywhere.
Retain both the original SI assumption and its admitted internal enclosure.
Voltages and charges hold throughout the interval; rate/current enclosures hold
almost everywhere. No new constant/clock/ramp implementation is introduced.

In particular, U identically 0.5 together with derivative identically 1 over
positive h is not established as a nonempty family. The upper production seal
must compare the actual unrestricted Timing family's complete joint hulls
(including its constant members), not select a convenient member or trust these
two supplied ranges. A conditional Native result alone cannot pass that seal.

### Initial state and the same implicit branch

Use the same selected-source order, actual forest, increasing B and canonical
complement L for both phases. Derive initial Values from the initial context
and initial U ranges. Run the qualified initial-root operation with explicit d0,
initial Z/center/Y and the actual original D. Only after its success obtain q0
from its retained actual full checked-Z0 Q query; no independent charge input or
implicit DC state is accepted.

For the window, derive Values on the full time/source window and window Z.
Construct the charge chart internally with H=(L P Q-q, B P F0), the actual
source derivatives and the same-owner original control. Source model/setup,
topology/projection, instance inventory, conditions, worker/numeric/semantic
profiles and non-time original-D coordinates must match the initial phase.
Initial and window context times are compared to their respective derived
queries; they are not required to be identical.

Before Picard, require all of the following using compensated containment:

1. The FULL checked initial Z endpoint box is contained in the window chart's
   checked Z endpoint box, in the identical reduced-coordinate order.
2. Initial U ranges are contained in window U ranges, with identical source
   device, endpoints, rails, normalization and setup/source identities.
3. The entire outer actual q0 enclosure is contained in the Picard charge box.
4. The entire Picard charge box is contained in the parameter box actually
   certified by the window chart.

For item 2, the actual source voltage enclosures are immutable finite
`CompensatedEnclosure` values from the same bound source law. Their synthesized
equality compares the normalized finite twofold center and finite nonnegative
radius, so equal values denote exactly the same enclosed set. Preserve the
existing window `A.bounds` computation and its fallible validation before any
identity shortcut. If the initial and window voltage CEs are exactly equal,
accept their set containment by identity rather than subtracting two independently
rounded interval expressions. For unequal CEs, retain the existing conservative
subtraction-based containment unchanged. This changes neither source assumptions,
rail/time normalization, actual law/query identity nor any arithmetic primitive.
Finite CE components alone do not justify skipping the existing outer-bound
overflow checks. The regression must execute the complete public conditional
flow with the same full normalized [0,1] initial/window family, and must retain a
real unequal outside-window refusal; initial-set coverage and family nonemptiness
remain upper obligations.

For item 4, derive exact represented Picard endpoints from the request's CE
charge box, then outward-enclose those endpoints for the lower chart's CE charge
parameters BEFORE certification. The hull constructor chooses a represented
center and a radius at least each endpoint's outward absolute distance from that
center. This constructively proves that BOTH exact Picard endpoints, hence their
entire interval, are inside the CE parameter box. After chart success require
exact equality of the retained chart parameter and that constructed CE. Do not
re-subtract the whole hull from its own rounded outer endpoints: independent
radius rounding can refuse self-containment even for center=1, radius=1 and the
exact interval [0,2]. This construction/equality join is not a relaxed tolerance
or an outer-bound-only containment inference. q0 membership still uses the
actual charge enclosure and Picard endpoints. Do not let endpoint rounding
extend Picard's domain beyond a narrower previously certified parameter box.
Retain both boxes.

The initial physical root therefore lies inside the window implicit chart and
satisfies its charge/algebraic equations for its own actual q0/phi0. Strict
uniform chart uniqueness identifies the same branch; q0 membership alone does
not prove this. The outer q0 may include non-root initial-Z points and can cause
sound refusal. No initial-state coverage/search claim is inferred from d0.

### Conditional Picard composition and output

Only the matched window chart supplies `NativePrescribedVoltageEvolution`.
Obtain its charge field `-L P F0`, its charge-state Lipschitz bound and its
full-coordinate/rate/current enclosures internally. No caller field or bound is
accepted. Reuse `ValidatedPicardSlab.certify` with the actual q0, full Picard Q,
derived field, exact h and same original control. It must check initial and
endpoint inclusion and outward hL<1. A zero dynamic dimension refuses this
finite Picard profile; no nonempty numerical trajectory is fabricated.

The source-sound smooth chart and fixed admissible AC source history give a
Caratheodory charge field on the entire Q and time window. The uniform implicit
root and derivative bounds supply continuity and q-Lipschitz premises; the AE
source derivative bound supplies the reconstructed rates/currents where those
derivatives exist. Conditional on each actual source history and each initial
state represented by the checked initial operation, the Picard check supplies a
unique finite charge solution in Q on the slab. It does not select a common
solution across different histories or prove the premises' nonemptiness.

`NativePrescribedVoltageFlow` is a public final immutable Sendable class with a
private initializer. Its public scalar outputs are `dimension`,
`chargeCoordinateCount`, `selectedSourceCount`, `duration`,
`contractionUpperBound`, `endpointCharge(at:)`, `coordinate(at:)`,
`chargeRateAlmostEverywhere(at:)` and `selectedCurrentAlmostEverywhere(at:)`.
`coordinate(at:)` returns the retained window enclosure, not a claimed tight
endpoint state. Selected-current coordinates have the same AE qualification;
nonselected implicit coordinates are enclosed throughout the slab. Invalid
indices are typed failures. Scalar inspection constructs no new proof owner.

The private payload retains the actual initial Root, window Chart, Evolution,
Picard result, exact request/query scopes, preparation value evidence and all
leases. It exposes none of those package numerical objects for construction or
mutation. Copying the result retains the same evidence/leases; it never creates
a new request budget.

### Read-only public scope for an upper production seal

Provide `withScope<Result>(_ body: (borrowing NativePrescribedVoltageFlowScopeView)
throws -> Result) rethrows -> Result`. The view is `~Escapable` and borrows
immutable result-owned storage; no array is materialized per inspection. Its
construction is internal to the sealed result. Minimum contents are:

| Scope data | Actual owner / use |
|---|---|
| `preparation: NativeCircuitPreparationRecord` | Existing actual plan/IR, complete instances/axes, OSDI setup receipts/projections, operating conditions and fixed limits |
| Actual selected `NativeVoltageSourceFact` values with device indices | Existing checked signed terminal/branch association and actual bound source law |
| Retained public source assumptions and converted internal slope bounds | Exact initial/window U, rails, normalization and AE SI premise |
| Spatial original-D endpoints, derived initial/window contexts and exact t0/h | Compare actual query/time/profile scope; distinguish outward endpoint expansion |
| B/L, d0, checked initial/window Z, Picard Q and outer q0 | Complete finite numerical set used by the result; no omitted-coordinate interpretation |
| Actual per-model constitutive/chart bindings and worker/profile/options | Existing SDK binding values include model reference, descriptor, program/setup/semantic identities, topology and coordinate quotient; retain the phase/query context with each |

The exact view fields are `preparation`, `sources`, `models`, `originalLower`,
`originalUpper`, `startTime`, `duration`, `initialContext`, `windowLowerContext`,
`windowUpperContext`, `algebraicRows`, `chargeRows`, `dynamicInitialCoordinates`,
`initialCharge`, `initialReducedLower`, `initialReducedUpper`, `windowReducedLower`,
`windowReducedUpper`, `chargeLower` and `chargeUpper`. Indexed vectors are borrowed
`Span` values of the corresponding CE, CV or Int type; source/model vectors are
`Span<NativePrescribedVoltageFlowSourceScope>` and
`Span<NativePrescribedVoltageFlowModelScope>`. Contexts are existing
`OSDIPrecisionContext` values. These view/source/model scope types have internal
initializers only.

`NativePrescribedVoltageFlowSourceScope` contains `deviceIndex: Int`,
`fact: NativeVoltageSourceFact`, `assumptions: NativePrescribedVoltageFlowSource`
and `internalNormalizedSlope: ClosedRange<Double>`.
`NativePrescribedVoltageFlowModelScope` contains `deviceIndex: Int`,
`preparation: NativeOSDIPreparationRecord`, `initialBinding`,
`windowBinding: OSDIPrecisionConstitutiveBinding`,
`smoothBinding: OSDIPrecisionChartBinding`, `workerReference: ArtifactReference`,
`numericProfile: ContentDigest`, `options: OSDIPrecisionOptions`,
`coverLimits: OSDIPrecisionDecisionCoverLimits`,
`identityLimits: OSDIPrecisionConstitutiveLimits` and
`requestedPrecisionBits: UInt32`. The last value records a request policy; it is
not an invented observation of every worker attempt's used precision. Actual
local proof owners remain retained privately. Raw/active/global association is
available from these existing SDK bindings, setup topology and actual preparation
projection; no inferred or omitted row map is substituted.

Existing plan/IR/receipt values are shared from their immutable owners. Scope
metadata that must be assembled is admitted before construction. Source scope
values retain the existing actual fact/lease; model scope values privately retain
the initial root, window chart and flow metadata reservation. Copying a value out
of a borrowed span therefore keeps its original backing admission alive without
exposing a constructor for a checked numerical result. Exact whole
candidate, PEX, library/process and rail authority is NOT accepted as a caller
label on this result. That missing actual producer/join is a separate Physical
responsibility; scope discovery does not grant it.

### Explicit capacity values

`NativePrescribedVoltageFlowLimits` contains explicit `maximumNativeTerms`,
`maximumTriplets`, `maximumPreconditionerNonzeros`, `maximumIntegerBits` and
`precisionBits`, plus named `values`, `reduction`, `chart`, `exact`, `root`,
`evolution` and `result` values of public nested `Capacity`. Each capacity value contains
`maximumRetainedBytes` and `maximumWorkspaceBytes`; no operational defaults are
guessed. Picard uses the result capacity's retained ceiling. Actual n/k/raw
counts checked against the existing fixed preparation limits provide the lower
dimension/source/row/column counts; caller triplet/preconditioner/integer ceilings
bound sparse and exact growth. Package lower limit types remain package types.

The capacity values bound their named lower phases/owner, not RSS or a second
independent global allocation budget. The preparation's Native floor-plus-live
ledger and original source resource owner additionally bound every simultaneous
phase, instance/helper, temporary, retained result and pending cleanup. The two actual m-element bridge buffers are admitted before construction. Their
backing is subsequently shared by lower Values; conservative logical phase
allowances may overlap for that backing, without a duplicate-buffer or RSS claim.
SDK managed program/setup backing is not charged again. No post-allocation
admission is introduced.

### Same-flow electrical voltage observations

This additive operation is implemented and behaviorally qualified on the
retained canonical public-candidate graph; its single scoped review, including
the P1 cancellation correction, is closed without remaining findings. The
existing flow construction and all existing scalar/scope inspection paths keep
their numerical behavior, storage and accounting unchanged. The purpose is to
expose already certified endogenous electrical voltage information to an upper
checked composition, without making an endogenous node a prescribed source.
It grants no Timing source-family, first-crossing, initial-cover or Physical
candidate correspondence authority.

The public operation belongs to the existing sealed flow:

```swift
public func observeVoltages(
    pairs: borrowing Span<NativePrescribedVoltageFlowVoltagePair>,
    limits: NativePrescribedVoltageFlowObservationLimits,
    cancellation: CancellationToken
) throws(NativePrescribedVoltageFlowObservationFailure)
    -> NativePrescribedVoltageFlowVoltageObservations
```

| Public value | Fields and meaning |
|---|---|
| `NativePrescribedVoltageFlowVoltagePair` | `positive: Node`, `reference: Node`; untrusted actual circuit node IDs, oriented as positive minus reference |
| `NativePrescribedVoltageFlowObservationLimits` | `maximumPairCount`, `maximumRetainedBytes`, `maximumWorkspaceBytes: Int`; explicit positive ceilings, no default or independent work budget |
| `NativePrescribedVoltageFlowVoltageObservation` | `pair`, `initialVoltage`, `windowVoltage`, `almostEverywhereRate: CompensatedEnclosure`; the latter three are respectively V, V and V/SI-second enclosures |

`NativePrescribedVoltageFlowVoltageObservations` is a public final immutable
Sendable result with an internal/private complete initializer, `flow:
NativePrescribedVoltageFlow`, `count: Int`, checked `observation(at:)` and a
lexical `withObservations` borrowing its result-owned observation span:

```swift
public func withObservations<Result>(
    _ body: (borrowing Span<NativePrescribedVoltageFlowVoltageObservation>) throws -> Result
) rethrows -> Result
```

The result exposes `public let flow: NativePrescribedVoltageFlow`, the EXACT
retained invoking owner, not a caller annotation or reconstructed equal-looking
record. Handoff takes this observation result as its authority and derives the
flow/context/source scope from `observations.flow.withScope`; it must not accept
a separately supplied Flow as the observation's owner. The result retains that
flow, its original control and the new result reservation. No public initializer
or evaluator can manufacture an observation result. Copied scalar observation values are data; their checked association is
the owning result plus its retained `flow`, not a caller-created table of CE
values. The retained flow's existing `withScope` supplies its actual preparation,
exact t0/h, initial/window contexts, source/rail assumptions and model bindings;
these are not duplicated in each observation. Every observation covers that
same initial time and entire finite slab. It is not an endpoint-only voltage.

Reject an empty request, a nonpositive ceiling, excessive count, unknown node
ID, or any non-ground endpoint not present as `.nodeVoltage(node)` in the
actual retained preparation's variable map. Validate the mapped row against the
same retained reduction plan's `.electricalPotential` nature. A thermal node or
flow axis is not an electrical voltage merely because it occupies a node-like
index. A branch coordinate cannot be supplied as a Node; a numerically reused
branch ID still denotes only the separately checked node namespace. The
original graph, node/row association and operating conditions remain retained
through the invoking flow. Node names or external labels are not accepted as
binding evidence.

Ground is exactly zero for initial/window voltage and rate and has no MNA row.
Equal endpoints (or the same validated coordinate) yield exact zero rather than
subtracting two independent copies of an interval. For distinct endpoints use
outward CE subtraction in the explicit positive-minus-reference orientation.
No floating component is assigned a new zero reference: its original forest
root's checked reduced coordinate and reduced rate remain present. A floating
absolute potential therefore retains its original conditional gauge enclosure;
a differential request does not silently tighten away that uncertainty.

#### Reuse of the retained value and rate owners

Initial voltages are read from the retained initial root's
`checkedQValues.reconstructionPayload(record:).lift`. This is the actual
whole-checked-initial-Z query made AFTER strict initial-root success with the
same initial phi, contexts and source binding. Window voltages use the same
retained Evolution Application as `flow.coordinate(at:)`; neither initial nor
window values use the original unexpanded proposal, root image clipping or a
new source query.

Evolution already retains the matched reduced rate `zDot` and its chart retains
the actual physical source slope `phiDot`. For this Flow profile the single AE
input derivative bound was fed to both internal side slots; use one matched
slot consistently. Chart's `spatial.leftSlopes` is already in V/SI-second:
BoundPrescribedVoltageLaw performed `delta * normalizedSlope / timeScale`
after Flow converted public dU/dSI-second outward by the same positive
`timeScale`. Applying that scale again would be incorrect.

Construct ONE existing forest `lift(zDot, phiDot)` and obtain
`A*zDot + E*phiDot` for nonselected-current coordinates. This uses the same
actual plan and outward signed-edge arithmetic as the qualified coordinate
lift, not a second MNA model, inverse, differentiation oracle or source query.
The existing Evolution accumulation's temporary `lift(zDot, zeroSources)` is
only `A*zDot`; `leftCharge` is QDot and cannot serve as a voltage derivative.
The new full rate lift is operation-local and is discarded after extracting
requested pairs. No derivative of a selected source CURRENT is claimed.

The existing primitive performs one O(n+m) bounded forest walk and fixed-size
workspace/result allocation. Reuse it once per observation operation rather
than walking an arbitrarily deep parent chain for each of p requested pairs
(O(p*n) worst case). This choice follows the actual primitive's fixed layout
and existing admission path, not an unmeasured speed claim. No dense matrix or
global inverse is constructed. Initial/window lift reads and pair extraction
are O(p); all pairs remain in caller order, including repeated requests.

#### Observation admission, failure and lifetime

The per-call observation token B may differ from preparation token A. The
implemented cancellation correction uses the existing Reduction overloads
`makeWorkspace(plan:cancellation:)` and
`lift(workspace:reducedCoordinates:sourceValues:cancellation:)`, forwarding B
through the single Evolution rate-lift helper. These overloads keep the same
original plan and mandatory A control; B supplies only additional cancellation.
Check B at validation, after each reservation before initialization, after the
original initialization charge and at every bounded zero/fill/forest/copy tick,
including after a control checkpoint that can invoke a caller accountant. No
later Lift reservation or work may occur after an observed cancellation. The
unchanged old overloads do not add a per-call token or alter their old arithmetic,
quantities, validation/checkpoint order or ownership. There is no same-token
assumption, budget reset, replacement plan/control or shared token registry.
The deterministic red canceled B at the inner 3n workspace reservation and at
the forest work checkpoint while A remained live. It observed a fourth Lift
reservation in both cases and 272/4 work units after cancellation, respectively,
instead of zero. The unchanged two cases now pass with three reservations and
zero later reservations/work. Typed cancellation, refund and reuse of the same
live original owner remain verified. The P1 finding-limited recheck is closed;
actual cancellation remains a typed cancelled failure.

The only control is the original flow preparation's mandatory cumulative
control. Match the retained initial, chart, Evolution and preparation owners
before any allocation; never accept a replacement control, root, rate or
matrix. Check the supplied token, Task cancellation and original control
before work, in bounded loops and before publishing. No source helper is
opened and no async borrow is needed.

Before initializing retained observation rows or copying node pairs, admit
checked result bytes: the result owner's managed payload/header, one Array
value header and `p * MemoryLayout<Observation>.stride`. The result row embeds
its pair, so no separate retained pair array is required. Input Span storage
remains caller-owned and is borrowed only during the synchronous call. Reserve
only the new observation storage; the flow's already admitted lower owners and
SDK program/setup buffers are retained by reference without a second charge.
The new result reservation must outlive its row storage and be released only
with the last owning observation-result reference.

Use the existing reduction's same-owner workspace and rate-lift allocations.
Its three n-element CE workspace arrays and one n-element CE Lift coexist until
pair extraction is complete. Before creating either, check their combined
managed-payload byte count plus their owner/header storage against the explicit
observation workspace ceiling using checked count/stride arithmetic. Those
allocations must also pass the existing reduction's unchanged own limits and
original global Native floor-plus-live/source ledger. The concrete local layout
is `retained = stride((Flow, Storage)) + p*stride(Observation)` and
`workspace = 4*n*stride(CE) + metadata`, where metadata is the sum of strides of
`(Plan, [CE], [CE], [CE], any Sendable)` and `(Plan, [CE], any Sendable)`, matching
the lower Workspace and Lift stored fields. The local metadata reservation
covers those additional managed owner fields; lower existing reservations cover
the actual 3n/n element buffers. These are managed payload formulas, not heap
allocator-header or process-RSS estimates. A virtual local byte
ceiling is not a second reservation. Each actual lower reservation is charged
once through its existing owner; do not pre-reserve a duplicate global allowance
for the same workspace. Any additional operation-owned row/index scratch must
be included and reserved before allocation; the implementation needs
no n-element row map or copied source/rate arrays.

Charge validation, initialized payload, actual lower forest traversal and pair
extraction through the same cumulative work owner before their corresponding
work; no budget reset or work refund. Releasing temporary lifts/workspace and
failed result storage refunds only their actual reservations. Existing flow
storage remains live and reusable after observation failure or result release.
No global cache, shared mutable scratch, unsafe pointer, target-dependent state
or new controller is introduced. The output and all shared retained owners are
immutable Sendable; operation-local lower Workspace remains non-Sendable and
synchronously exclusive as in the existing reduction contract.

`NativePrescribedVoltageFlowObservationFailure` cases are
`invalidInput`, `unknownNode(Node)`, `nonElectricalNode(Node)`, `capacityExceeded`,
`cancelled`, and `operation(cause: any Error)`. Preserve actual quota/storage,
arithmetic and other lower failures as the `operation` cause; normalize only
recognized cancellation failures. No failure returns a partial result or
replaces a failed query/rate with zero. Existing Flow failures and their cleanup
capabilities remain unchanged; the observation operation creates no helper or
cleanupPending owner of its own.

The implementation ownership is this component: pair/limits/row/result/
failure/assembly files, the additive method in `NativePrescribedVoltageFlow.swift`
and one minimal same-owner internal method in
`NativePrescribedVoltageEvolution.swift` to pass its retained rates directly to
its matched reduction's lift without extracting/copying rate arrays. Test owners are `NativePrescribedVoltageFlowObservationTests.swift` and
`NativePrescribedVoltageFlowObservationOSDITests.swift` in CoreSpiceOSDINativeTests.
No new child component or parent index entry is needed. No Physical or Timing code
may reconstruct this affine derivative from MNA metadata. The existing public
Flow path does not compute or retain observation data unless this operation is
explicitly requested.

## Runtime Flows

Validate finite shapes/source selection/time, controlled actual owner and all
checked capacity arithmetic. Admit the flow's own metadata/workspace before
initialization/copy. Construct initial Values/root, window Values/chart, check
the full branch/set join, then reconstruct Evolution and run Picard. Close each
exclusive source helper before publishing its retained scope. Check per-call
and Task cancellation before/after every await and before result publication.

All helper resources and lower result owners coexist according to their actual
lifetime. A failed phase cannot publish its intermediate Root, Chart or Picard
result through the public operation. Later source queries do not reset earlier
work or replace an owner with an equal-looking record.

## State, Ownership, and Lifecycle

| State | Storage / isolation | Lifetime |
|---|---|---|
| Input request arrays | Caller-owned immutable Array backing | Retained where shared by the sealed result; copied output metadata is separately admitted |
| Actual controlled preparation | Existing record/control and exclusive prepared devices | Borrowed for the async operation; value evidence/source leases retained by result |
| Shared work/storage/cancellation | Existing unconditional Mutex control and original source resource owner | All phases/boxes/helpers, no reset or work refund |
| Lower Root/Chart/Evolution/Picard | Their immutable existing owners and original leases | Last flow result/reference using them |
| Scope metadata and bridge vectors | Pre-admitted immutable result storage / operation-local scratch | Result or operation exit respectively |
| Voltage observation result | Immutable Flow reference, row Array and original reservation | Last observation-result reference |
| Voltage observation scratch | Synchronously exclusive existing lower Workspace/Lift and temporary metadata ticket | Observation operation exit |
| Failed helper cleanup | Existing `OSDIConstitutiveCaptureCleanup` Mutex owner | Explicit successful retry; leases remain live while pending |

No new shared mutable state, unsafe pointer, conditional synchronization,
controller, callback registry or borrowed span crossing await is required.
Helpers use scoped borrows only after immutable owning inputs are retained.
The flow result has no foreign live helper and needs no shutdown method; the
exclusive preparation and any failed pending cleanup keep their existing close
responsibilities.

## Failure, Concurrency, and Constraints

`NativePrescribedVoltageFlowFailure` is a public typed Error/Sendable value with
`invalidInput`, `missingControlledPreparation`, `invalidBinding`,
`unsupportedProfile`, `capacityExceeded`, `cancelled`,
`uncertified(Phase, cause: any Error)`,
`capture(Phase, cause: OSDIConstitutiveCaptureFailure)`,
`smooth(Phase, cause: OSDISmoothRangeFailure)` and
`phase(Phase, cause: any Error)` cases. Phase identifies initial Values,
initial root, window Values, window chart, branch join, evolution, Picard or
scope publication. Lower mathematical refusal remains its original cause, not
nonexistence. A coincident cancellation does not replace an unrelated failure.

The existing constitutive/smooth failures and cleanup type/close are public
capabilities under the approved minimal CoreOSDI visibility change;
constructors/helpers remain package/internal. A lower smooth/capture
`cleanupPending` is retained inside its public actual cause with its actual
primary/secondary failures and exact existing retry owner. No wrapper
cleanup controller, lost retry owner, swallowed close error or success fallback
is permitted. Source work remains spent; only each actual released reservation
is refunded. The public operation must preserve the old ordinary preparation and
point-execution behavior.

## Verification and Change Impact

The public controlled-preparation and policy boundary is implemented by its
existing owner. The actual Physical candidate/circuit/rail producer remains a
separate uncompleted responsibility; it is not a premise silently supplied by
Native or a prerequisite for qualifying this explicitly conditional operation.

The dedicated suites passed nine declarations, ten cases, two suites and zero
skips in the r3 focused run (6.046 command seconds, 1.387 test-engine seconds).
They exercise:

- Active C2(d,0), R2(d,p), R4(x,p), V(p,0): nonzero actual charge field,
  positive derived Lipschitz/contraction, actual selected current and the
  constant-input analytic RC endpoint `2+(q0-2)*exp(-h/4)`. Enlarging h refuses
  contraction instead of accepting a fabricated zero field/bound.
- An isolated dynamic coordinate with a retained single SI AE derivative bound,
  without inventing everywhere one-sided derivatives or an implicit DC state.
- Full checked initial Z outside the window even when the root and q0 fit;
  actual q0 outside Q; ordinary/uncontrolled preparation; uncontained initial
  source U; capacity/storage denial; pre-spent same-control work; cancellation;
  copied result/scope-element lifetime and final refunds. Repeated scope borrows
  make zero additional Native reservation calls and materialize no arrays.
- Genuine concrete SDK policies, actual linear charge and a raw-alias/ground
  source projection, actual model/program/setup/worker/numeric bindings, and
  actual nonlinear charge refusing an asserted algebraic zero.
- Genuine helper startup cancellation in both ordinary-close and failed-close
  cases. The pending public cleanup owner retains its primary/secondary causes
  and leases; restoring the actual helper directory permits idempotent retry,
  final refund and reuse of the same preparation/control. Both parameterized
  cases executed, with no fixture skip.

The unchanged Root/Chart eighteen declarations/nineteen cases passed in the r2
run and retain that subset evidence. The enclosing r2 command FAILED the new
Flow charge-domain guard; it is not an overall green run. Its four selected old
Native-preparation declarations SKIPPED under their fixture guard and are
excluded from executed evidence. Prior lower Evolution/Picard evidence remains
owned by the linked lower designs; no new all-owner/scheduler qualification is
claimed.

Two causal failures and their fixed source snapshots are retained: r1 compile
rejected the temporary stored-payload borrow, fixed by the immutable local
owner/lexical view; r2 runtime rejected hull self-subtraction, fixed by the
constructive endpoint hull plus identical certified parameter binding specified
above. q0, full initial Z/U checks, source/query profiles, tolerances, ceilings
and the original tests were unchanged. The successful incremental r3 build took
56.953 seconds. There was no blind retry or budget/tolerance increase.

An independent ordinary-import public consumer compiled/linked against the
actual immutable object closure, executed actual controlled Native/SPICE
preparation and the analytic Flow/source-binding check in 1.636 seconds, and
passed five compile-refusal checks, including an explicitly typed borrowed-view
escape. Its earlier unused/Void-inferred negative is preserved as a harness
failure and excluded from the final refusal evidence. No package/testable flags
were used by that consumer; package DI in the owner test only injects cancellation
after a genuine helper startup.

The single [Flow review](../../../../.verification/prescribed-voltage-flow-20261020/flow/review-r3.json)
is closed with no remaining findings. It binds the source, failed and successful
runs and [external public client](../../../../.verification/prescribed-voltage-flow-20261020/public-preparation/external-r1/receipt.json).
The compact final closure maps these qualified premises to the comment-only
final source. The qualification uses the existing development graph and recorded
availability mirrors, not a new canonical public source release graph.

Changes to branch/domain construction, source/time units, policy authority,
lifetimes, admission or helper cleanup require the affected owner cases above
and the relevant lower contract checks. Source-family nonemptiness, complete
initial-set/root cover, continuation, all-phase/all-history/corner proof and
final fresh canonical public-graph qualification remain distinct and unclosed.

### Voltage-observation qualification

The new observation suites executed ten declarations/thirteen cases with zero
skips. The old Root/Chart/Flow subset executed twenty-seven declarations/
twenty-nine cases with zero skips in the same current linked binary. These are
focused owner results, not an all-package or full-history qualification. The
[green aggregate](../../../../.verification/prescribed-voltage-flow-observations-20261020/closure-final-r8.json)
binds the unchanged test bodies, runtime evidence and final comment-only source.
The tests exercise:

- The existing active RC fixture independently checks initial/window voltage,
  nonzero dynamic voltage rate and selected-source voltage rate; qDot must not
  be mislabeled as dV/dt. Compare the analytic constant-input RC solution and
  the independent signed resistor/source relation.
- A nonunit timeScale and nonunit/reversed voltage rails check V/SI-second
  conversion exactly once. Reverse the node pair to test orientation; equal
  endpoints and ground-ground give exact zero.
- A floating source component retains a nonzero root/gauge coordinate and rate;
  differential and ground-referenced observations cannot fabricate a grounded
  component. Actual unknown, thermal and branch-ID namespace cases refuse.
- Genuine existing SDK linear/alias projection keeps actual original node,
  setup/profile/source/time binding; observation cannot promote a different
  flow's record, an unrelated node or an endogenous node to a prescribed input.
- Explicit local workspace/result/count refusal, original global reserve/work
  refusal, pre-spent repeated operations, cancellation and checked byte overflow
  exercise the same owner. Failure leaves the flow reusable and no temporary
  reservations live. Copied observation results retain the invoking flow and
  original leases until the final reference; final release refunds new storage.
- Repeated borrowed observation-span inspection performs no additional
  reservation or work charge and materializes no arrays. The ordinary-import
  client executed six actual physical voltage observations, exact actual-flow
  association, units/orientation and final refund. Its two intended compilation
  refusals protect the private result constructor and borrowed observation span.

The [single observation review](../../../../.verification/prescribed-voltage-flow-observations-20261020/review-r7.json)
is closed with no remaining findings. It binds the original full pass, the P1
independent-token red/green and its finding-limited recheck, source/compiled
closure and the ordinary-import external-client evidence. The first compiler
failure was the borrowed payload capture, corrected only by retaining the same
Evolution owner as an immutable local. The earlier six Picard refusals occurred
before observation: their test's broad OriginalD field did not self-map its new
narrow Q. The tests now propose the justified smaller spatial OriginalD with all
initial/window boxes and source voltages strictly contained; h, Q, Z, source,
model, limits, tolerances and assertions are unchanged. The 300-second red-build
timeout was not a red test result; the later successful build/runtime established
the six intended cancellation issues. The retained typecheck diagnostic disproved
the contextual-map hypothesis; no test rewrite or compiler safety change was
made for that hypothesis. Every failed attempt remains preserved separately.

The affected lower boundary is only existing reduction workspace/lift arithmetic
and Evolution's private matched-rate access; do not rerun unrelated model
schedules or infer full Timing/Physical/source-family completeness from these
finite observation cases. Existing qualified Flow behavior remains a regression
premise because its construction path, math and allocation are unchanged.
