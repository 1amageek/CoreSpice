# Actual-Owned Global Charge Kernel

## Purpose and Scope

Child of [NativeExecution](../DESIGN.md), with no children. Own one finite,
conditional proof of the complete constant-left zero-kernel of the actual global
Q function on an explicitly fixed constitutive domain. Status: implemented and
qualified on the finite behavioral paths recorded below. This is a certificate
checker for successful candidates, not a search that succeeds for every circuit.

## Responsibilities and Boundaries

The existing exclusive PreparedNativeCircuit constructs the result from its own
actual R/C/V and controlled OSDI producers. It checks global incidence, exact
source-bound null rows, independent-row completion and interval anchor regularity.
The result is privately constructed and retains its source/scope and admissions.
It does not certify F identities, source-current elimination, prescribed-source
history, a DAE solution, roots, continuation, a physical chart or foundry behavior.
Unknown producers and missing controlled preparation refuse. A caller protocol,
decoded receipt, point sample or asserted identity cannot replace an actual source.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Actual preparation, full axes and shared floor/delta ledger | No ordinary owner substitution |
| [RangeExecution](../../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | depends on | Actual-bound checked local identities, all raw rows and retained backing | Local membership alone is not complete global-kernel authority |
| [ExactRowAlgebra](../../../CoreSpiceAnalysis/ExactRowAlgebra/DESIGN.md) | depends on | Exact membership, zero products and verified invertible completion | No source meaning is supplied by algebra |
| [ValidatedMatrixRegularity](../../../CoreSpiceAnalysis/ValidatedMatrixRegularity/DESIGN.md) | depends on | Outward sufficient interval minor test | Uncertified does not mean singular |
| [ContinuousEquationStructure](../../../CoreSpiceDevices/ContinuousEquationStructure/DESIGN.md) | depends on | Actual complete represented-coefficient R/C/V laws | Enclosure values are not exact coefficients |

## Architecture

```text
borrow existing PreparedNativeCircuit + fixed domain + proposed N/anchors/R
  -> complete actual producer/axis inspection and common owner admission
  -> native exact charge terms + domain-scoped checked OSDI raw identities
  -> exact pullback/membership for every N row, plus exact native sum
  -> verified S=[N;L] completion
  -> same-global-anchor Q enclosure, summed over all aliases and instances
  -> outward minor LQ + independent regularity checker
  -> complete conditional global Q zero-kernel = rowspace(N)
```

## Contracts and Invariants

### Fixed domain and exact axes

The domain is the closed box on every original compiled global matrix coordinate,
with an exact represented lower/upper transient context time and one fixed mode.
Its meaning is constitutive, not a set of physical solutions or histories. All
bound parameters, topology, operating conditions and simulation setup remain those
of this prepared owner. Every global axis, including body, thermal and internal
flow coordinates, is retained. Ground has no global unknown and is exactly zero.
There is no hidden source-family, physical-rail or source-equation restriction.
Those stronger domains require an upper join rather than reinterpretation here.

Each anchor has one full global represented point and one context inside that
same box/time/mode. Projection to each actual active coordinate uses the checked
raw/active/global map. Aliases receive the same value and mapped ground receives
zero. All local projections are validated against the actual capture inventory
before successful publication. No independent per-device anchors are accepted.

### Exact null rows

The proposal supplies p dyadic rows N of full global width n. Every imported
coefficient retains its exact sign, numerator words and denominator power. Native
coefficientBits are imported as exact represented dyadics, never through rounded
sums. All native charge terms from all instances are included, so cancellation
between those terms is checked as an exact sum. Native R and V have Q identically
zero by their complete actual law; no waveform is replaced or differentiated.

For each OSDI device, raw row j pulls back a global row lambda as lambda[global(j)],
or exact zero at ground. Raw rows are not deleted before this operation. Aliased
raw contributions sum, rather than overwrite. The pullback must be a verified
member of that device's full-domain reactive identity row space. Every domain
query retains its complete original box/context, binding and whole-cover scope.
Identities returned by later anchor queries are never promoted to the full domain.

An interval containing zero is not an identity. Native point caches, sampled
Jacobians and thresholded ranks play no role in NQ=0. Per-device membership is a
sufficient source proof; a missing cross-instance nonlinear identity causes a
candidate refusal, never a claim that the proposed N is complete.

### Completeness from legal Q-value anchors

Exact completion rejects dependent N and checks an invertible S=[N;L], with L the
ordered coordinate selectors returned by ExactRowAlgebra. Put r=n-p. For r>0,
exactly r anchors are required. Each actual capture is evaluated on each projected
anchor under the same session and source/setup. Every cover leaf contributes to
an outward hull of every raw Q row. All raw aliases and all instances are then
added outward into the common global Q column, alongside native C contributions.
The interval minor has entries (L Q(anchor_j))_i. The explicit proposed approximate
inverse R is checked independently by the existing regularity kernel.

Source checking proves Q(D) is contained in ker N, of dimension r. A regular
anchor minor proves r independent actual Q values within D. Therefore their span
is ker N, and the complete functional constant-left zero-kernel on D is rowspace
N. Here r is the functional span dimension of Q values, not a DAE/state dimension or
a derivative-rank claim. No derivative-rank replacement is permitted. With r=0, full-rank N and NQ=0
already close the claim; no zero-dimensional regularity operation is invoked.
Opposite-charge instance cancellation with insufficient N cannot pass the anchor
rank test, even though the source relations themselves are sound.

## Runtime Flows

One package borrowing operation on PreparedNativeCircuit owns composition and
holds the actual owner across asynchronous capture creation. Each capture runs a
full-domain identity query and all anchor queries using its existing session,
then closes before the next capture and before ordinary owner closure. Borrowed
SDK views are consumed synchronously; neither a view nor a span crosses await.
Only preadmitted owned coefficient/scope copies and original retention values
survive. Any failed source query, callback or close prevents a successful result;
cleanupPending retains its original primary/cleanup causes and release authority.

## State, Ownership, and Lifecycle

The native-only package preparation lane is owned by the parent design. It uses
the original compiler/binder and seals an empty foreign-program backing when the
actual circuit is entirely native. Ordinary uncontrolled preparation refuses here.

All work and storage use the existing Native controlled preparation owner; no new
budget, reset or guessed quota is created. Exact algebra and regularity accept
that existing mandatory execution-control contract. Their old budget/storage
entry points retain their existing dimension/admission semantics. Explicit limits
bound null rows, coefficient limbs, native terms, anchor cells, local projection
scratch, minor cells and retained result bytes. Checked arithmetic and admission
precede initialization and copying. Every actual traversal/product/copy is charged.

| State | Owner / isolation | Release |
|---|---|---|
| Prepared devices and compiled axis | Existing exclusive prepared circuit | Existing ordinary lifetime |
| Native floor/delta and source work | Existing unconditional Mutex ledger / source accountant | Existing reservation tickets |
| Capture helper | Existing noncopyable capture and private Mutex checkout | Explicit close or retained cleanupPending |
| Exact coefficients and scope | Immutable admitted result backing | Final extracted coefficient/result copy |
| Numeric scratch | Operation-local exclusive arrays | Success or every throw |

No target-specific raw state, unchecked Sendable or unsafe memory is introduced.
Storage callbacks and foreign operations remain outside ledger locks. Retained
scope includes preparation, domain/context, actual snapshot/inventory bindings,
full-domain exact rows and completion/regularity facts. A result does not retain
an executable view into a closed helper.

## Failure, Concurrency, and Constraints

Invalid shape, noncanonical coefficients, dependent N, illegal anchors, mismatched
context/axis/map/source, missing control/snapshot, unsupported producer, failed
membership, uncertified minor, arithmetic/resource exhaustion and cancellation
publish no partial success. Original control and capture cleanup causes propagate.
The entry does not consume or close the ordinary prepared owner on refusal.
Retry uses the same remaining cumulative allowance. A success proves the fixed
conditional domain only and cannot be moved to another preparation or history.

## Verification and Change Impact

New Native owner tests exercise actual prepared floating C and the qualified
actual OSDI capacitive fixture, with original source/program/worker pins. They
cover alias sums and ground-zero pullback, all axes, r=0, illegal anchors and
context/domain mismatches, missing/fake producers, exact cancellation, rank refusal
for an insufficient N under opposite-instance cancellation, original quota and
cancellation causes, complete cleanup and retained-copy refunds. The qualified original-source linear and analytic parabola fixtures exercise
Q=(t,t^2) with two legal value anchors, independently of its one-direction spatial
derivative. Their exact source/image/program/worker handoff binds the actual
Native integration; no fabricated program substitutes for source compilation.
One focused red, batched implementation/green and one scoped review own this leaf.
Changes to control plumbing require the affected exact-algebra and matrix owners;
no Timing, original-C exporter or full root/history qualification follows.

Finite qualification is owned by
[Native tests](../../../../Tests/CoreSpiceOSDINativeTests/NativeGlobalChargeKernelTests.swift)
and [actual-source tests](../../../../Tests/CoreSpiceOSDINativeTests/NativeGlobalChargeOSDITests.swift).
The combined run passed 15 tests in two suites without skips. One review finding
strengthened the signed-cancellation test: the same candidate now accepts actual
+1/+1 charge and refuses +1/-1 specifically at minor regularity, with refunds.
That corrected test passed separately; the other 14 tests and all production
files remained unchanged. Existing ExactRow tests passed 16 cases; matrix tests
passed 13 declarations including 14 argument cases, without skips. One full scoped
review and its one finding-limited recheck closed without remaining findings.
Reproducible source/model pins and stage receipts are recorded under
`.verification/global-charge-kernel-20261020/native/`, including
`runtime-r4.json`, `runtime-exact-r5.json`, `runtime-matrix-r5.json` and
`runtime-finding-r6.json`; the final aggregate is `final-qualification-r7.json`.
These facts qualify only the conditional functional Q-kernel responsibility above.

The private `NativeGlobalChargeSourceCapture.reactiveRows` importer is also used
by [PrescribedVoltageChart](../PrescribedVoltageChart/DESIGN.md). It imports only
reactive identities from a checked capture using the original retained arena;
it adds no global row, completion, anchor or rank authority. Each caller owns
its exact source/query binding and raw pullback membership checks.
