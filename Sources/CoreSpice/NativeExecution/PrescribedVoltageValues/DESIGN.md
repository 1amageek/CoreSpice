# Actual Prescribed Voltage Values

## Purpose and Scope

Child of [NativeExecution](../DESIGN.md), with no children. Own one same-prepared-
owner admission and outward evaluation of all original F0/Q values after an
explicit prescribed ideal-voltage affine substitution. This is a finite conditional
value contract, not a root, DAE rank, OSDI derivative, seam, flow or history proof.
Status: finite conditional value implementation qualified on the fixed Swift 6.4.0 / macOS 27 native path.

## Responsibilities and Boundaries

Only actual sealed Native R/C/V and actual controlled OSDI sources participate.
Selected actual V devices use their private bound external-coordinate factory;
unselected V must have an actual constant DC Waveform. Any unselected dynamic V
requires explicit selection and otherwise refuses. Ordinary point/waveform paths
are unchanged. F0 removes selected source-current incidence symbolically. Selected
constraint rows are exactly zero on the correlated affine image, not on every
point of an independent interval hull. Q retains every original row. No source
current, numerical derivative or physical certificate is returned.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Actual producer inventory and shared preparation control | Ordinary uncontrolled preparation refuses |
| [Devices](../../../CoreSpiceDevices/Devices/DESIGN.md) | depends on | Actual BoundVoltageSource factory and represented R/C/V laws | Explicit external inputs remain assumptions |
| [PrescribedVoltageReduction](../../../CoreSpiceAnalysis/PrescribedVoltageReduction/DESIGN.md) | depends on | Checked forest and shared value-only affine lift | Current reconstruction is not invoked with fake rates |
| [RangeExecution](../../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | depends on | Actual-bound full F/Q cover and immutable capture retention | No G/C or source-seam promotion |
| [GlobalChargeKernel](../GlobalChargeKernel/DESIGN.md) | coordinates with | Existing authority-free full-axis domain value | Functional Q span is not a DAE dimension |

## Architecture

```text
borrow actual PreparedNativeCircuit + original D + selected source inputs + z box
  -> full actual axis/producer validation and source read/write exclusion
  -> actual V factories + same-control checked forest
  -> phi(U) + affine lift of retained coordinates
  -> original-D current slots + contained outward lift box
  -> native exact-coefficient F0/Q and actual OSDI all-leaf raw F/Q sums
  -> private immutable value result, original scopes and shared admissions
```

## Contracts and Invariants

The package borrowing entry is `enclosePrescribedVoltageValues(originalDomain:
NativeGlobalChargeDomain, sources: [NativePrescribedVoltageSource],
reducedCoordinates: [CompensatedEnclosure], capture: OSDIConstitutiveCaptureInputs?,
limits: NativePrescribedVoltageLimits, cancellation: CancellationToken) async throws
-> NativePrescribedVoltageValues` on the existing PreparedNativeCircuit.

Each source input contains the actual `deviceIndex`, represented `zeroVoltage`,
`oneVoltage`, `timeOrigin`, `timeScale`, `normalized`, `leftSlope` and `rightSlope`
closed ranges. Slopes are explicit conditional input bounds required by the
existing bound-law producer; they are not inferred or granted family authority.
The original domain retains every compiled coordinate and exact transient context.
No Timing dependency or source-law rewrite is introduced. The host must establish
its distinct parametric analysis identity and physical rail/time/family join.

Every selected index must identify an actual BoundVoltageSource, exactly once.
All compiled axes and actual identities are joined first. For every remainder
producer, complete READ support must exclude selected branch-current rows, and
both F/Q WRITE supports must exclude selected constraint rows. Unknown support
refuses, including current-feedback devices whose sampled contribution is zero.
OSDI body, thermal and internal flow coordinates remain on their original axes.
Forest cycles/self loops and conflicting selected source ownership refuse.

The qualified actual factory supplies the same real phi(U) used by its point F
kernel. Its compensated endpoint difference is never replaced by a guessed
binary64 slope. The forest's affine lift is shared with the existing apply path,
with that path's arithmetic, order and work schedule preserved. Before source
current reconstruction, the lift has no value for eliminated current rows; its
getter explicitly refuses those rows. Native preserves their ORIGINAL D lower/
upper endpoints as formal legal evaluation intervals. They are not physical
reconstructed currents and zero need not lie in those intervals.

Every other outward lifted coordinate must lie wholly inside original D before
any source query. Independent hulls may overapproximate the correlated image;
no source equation is claimed on the larger hull. Actual native represented
coefficient terms evaluate F0/Q outward; selected V contributions are handled by
exact incidence/constraint identities. An unselected `.dc(value)` uses that actual
private Waveform scalar, retaining its source fact. All raw OSDI F/Q rows on every
cover leaf are consumed, then aliases and instances SUM into original global rows;
ground is discarded only after checked raw mapping. No identity claim, point Q,
Jacobian or derivative is used as a substitute for those value enclosures.

The private payload also retains the original controlled reduction value and reduced
coordinate inputs for the same-owner [reconstruction](../PrescribedVoltageReconstruction/DESIGN.md)
consumer. This adds retained admission, not a current or derivative guarantee. The same
internal arithmetic boundary supplies checked nonnegative capacities, outward
represented enclosure endpoints and finite endpoint hulls to that consumer;
existing numerical/capacity failures propagate without a replacement arithmetic
or resource owner.

`NativePrescribedVoltageValues` has a private constructor and retains actual
preparation, original D, explicit source inputs/laws, forest, lifted scope, native
terms, closed capture source/scope retention and admitted output buffers. Its
package facts are `dimension`, `reducedCoordinateCount`, `selectedSourceCount`,
`capturedSourceCount`; checked indexed access returns `coordinateLower(at:)`,
`coordinateUpper(at:)`, `staticResidual(at:)`, `charge(at:)` and `sourceVoltage(at:)`.
The reduced count describes forest coordinates only, never state/DAE dimension.

## Runtime Flows

One borrowing operation performs structural admission, forest/law construction,
lift containment and whole-value assembly. Actual OSDI captures open under the
same preparation control, query the contained lifted box, consume borrowed views
synchronously and close before publication. No view or span crosses await.
Failures discard partial arrays and preserve primary/cleanup causes and pending
cleanup owners. Ordinary prepared execution ownership remains usable on refusal.

## State, Ownership, and Lifecycle

The existing NativeConstitutivePreparationControl owns cumulative work, original
cancellation and the shared ordinary floor/live-delta ledger. No new budget or
reset is created. Explicit limits bound native term counts, retained payload,
workspace and reduction tables; checked capacities and leases precede allocation,
initialization and copies. Immutable result copies retain their admissions.

| State | Owner / isolation | Lifetime |
|---|---|---|
| Actual devices/axis | Existing exclusive prepared circuit | Borrowed operation |
| Shared floor/work/storage | Existing unconditional Mutex control/accountant | Original reservation tickets |
| Forest and lift | Existing controlled reduction owner | Immutable retained plan/lift leases |
| Model capture | Actual snapshot and capture storage | Explicit close before return |
| Values/scope | Immutable private result | Final result/reference release |

There is no unsafe storage, unchecked Sendable, target-dependent state or callback
under a ledger lock. Caller input arrays remain caller-owned until retained under
admission. Managed payload accounting is not a zero-allocation or RSS claim.

## Failure, Concurrency, and Constraints

Typed request failures cover invalid shape/binding/domain, missing control/capture,
duplicate/non-V selections, unselected dynamic V, illegal structural dependencies,
lift outside original D and capacity exhaustion. Original reduction, numerical,
resource, cancellation and capture cleanup causes propagate. No partial result,
fallback waveform, fabricated zero charge-rate or physical-current success exists.

## Verification and Change Impact

New NativePrescribedVoltageValuesTests and PrescribedVoltageLiftTests exercise
actual source ownership, unselected DC/dynamic policy, current-domain intervals
excluding zero, original-axis/ground/reversed/floating incidence, cycles, wrong
owners, containment, full F0/Q values and cancellation/quota/refund lifetimes.
NativePrescribedVoltageOSDITests owns actual source captures, all-leaf/alias sums,
original source scopes and refusal controls. C2/R4/phi=2U, T=2, U=.5 must enclose
v=1, Q=2 and F0=.25. Native-only analytic dQ/dt=2 independently yields i=-2.25;
omitting prescribed charge rate gives -.25 and is a falsifier, not an OSDI current
or derivative certificate. Existing reduction apply tests verify unchanged order
and arithmetic.

Qualification: the new Native/actual-OSDI path passed 10 test declarations (11
argument cases, two suites, zero skips), including four actual OSDI capture tests.
The lower value-only lift and unchanged reduction path passed 19 tests (four new
lift tests plus 15 existing reduction tests, two suites, zero skips). The fixed
Swift 6.4.0 release builds and runtimes are retained in
`.verification/prescribed-voltage-values-20261020/{build-native-r3,runtime-native-r3,build-analysis-r3,runtime-analysis-r3}.json`.
One comprehensive scoped review by `release_fix_export` closed with no concrete
finding; no recheck was needed. This evidence establishes the finite conditional
F0/Q value contract above and does not extend it to physical currents, derivatives,
roots, flow, history or DAE/state dimension.
