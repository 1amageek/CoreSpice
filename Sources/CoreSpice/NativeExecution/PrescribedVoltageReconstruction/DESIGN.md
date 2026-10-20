# Prescribed Voltage Reconstruction

## Purpose and Scope

Child of [NativeExecution](../DESIGN.md), with no children. Own the same-prepared-
owner closed-smooth-slab charge-rate action and reconstruction of every selected
ideal-voltage-source current. This is conditional outward arithmetic, not a root,
flow, entire-history, state-dimension, or source-seam certificate.
Status: finite conditional reconstruction qualified on the fixed Swift 6.4.0 / macOS 27 native path.

## Responsibilities and Boundaries

Use actual Native R/C/V coefficients and same-source SDK smooth spatial C bounds.
Keep the existing value-only admission and original D; reconstruct left and right
sides separately, then require every reconstructed coordinate inside D before
publication. Op3/4/5 source AD-root formulas are not derivative authority. All-plane
Jacobian construction, explicit-time Q partials and nonsmooth continuation remain
outside this responsibility. Ordinary point/waveform execution is unchanged.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Actual complete producer inventory and original preparation control | Uncontrolled or other prepared owners refuse |
| [PrescribedVoltageValues](../PrescribedVoltageValues/DESIGN.md) | depends on | Private retained original-domain values, source laws, exact forest and checked outward arithmetic | Formal selected-current intervals are not physical currents |
| [PrescribedVoltageReduction](../../../CoreSpiceAnalysis/PrescribedVoltageReduction/DESIGN.md) | depends on | Original retained reduction/plan, linear lift and full-row apply | Residual intervals containing zero are not equation proofs |
| [Devices](../../../CoreSpiceDevices/Devices/DESIGN.md) | depends on | Actual phi and one-sided SI law jets | Normalized slopes remain explicit assumptions |
| [RangeExecution](../../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | depends on | Sealed actual-bound protocol-2 smooth range and retained exact query scope | Time-input and demanded nonsmooth dependencies refuse |

## Architecture

```text
borrow actual PreparedNativeCircuit + privately bound Values + left/right zdot
    -> verify same original control and actual complete inventory
    -> actual phiDot_left/right = delta * normalizedSlope / timeScale
    -> exact forest tangent lifts: A zdot and E phiDot
    -> native represented C + actual smooth raw C actions, summed globally
    -> existing apply(F0, stateRate, prescribedRate, proven Qt=0)
    -> all original coordinate intervals contained in original D
    -> private immutable left/right reconstruction and original source scopes
```

## Contracts and Invariants

The package prepared-owner entry is
`reconstructPrescribedVoltageCurrents(values:leftReducedRates:rightReducedRates:range:limits:cancellation:)`.
The original Values privately retains the original reduction value and reduced
coordinates as well as its plan. The operation requires that Values' preparation
control is the same object as the actual borrowed prepared owner's control. Actual
producer validation is repeated; no caller-created claim or decoded record is
accepted as executable source authority.

Rate inputs have the original forest reduced-coordinate order and physical-second
units. Existing actual source laws convert normalized source-time slopes once:
`phiDot = (oneVoltage - zeroVoltage) * normalizedSlope / timeScale`. Time origin
and original contexts remain retained. Left and right reduced/input rates are
separate. The exact affine basis gives `xdot = A zdot + E phiDot`. Complementary
zero vectors used in these two linear tangent lifts are algebraic basis zeros,
not invented physical charge rates. Selected current coordinates remain unavailable
in both tangent lifts; the previously checked full READ exclusion proves that no
remaining source needs those derivatives.

Native represented charge terms and actual smooth raw C compute separately
`stateRate = C A zdot` and `prescribedRate = C E phiDot`. Raw derivative columns
and rows both sum through actual aliases. Raw ground coordinates have zero rate;
raw ground rows are scanned before being discarded. Every retained body, thermal
and internal-flow coordinate participates. No global Q-value-span rank is used.

For each actual OSDI device the owning bridge uses the concrete SDK evaluator and
checks immutable program/setup/topology/worker/profile/options and the full
unchanged lifted closed coordinate/time box. It rejects explicit time input and
any demanded nonsmooth, undefined, unsupported or nonfinite range operation before
publication. No leaf AD formula, finite point, unproved seam subdivision or caller-
supplied Qt=0 flag substitutes for this result. Native R/C and actual constant DC
have zero explicit-time charge partial; the time-independent smooth source result
has Qt=0 with immutable setup/ambient/nominal conditions. Selected phi time variation
is accounted for by the prescribed-input rate, not by Qt.

Existing apply computes `r=F0+stateRate+prescribedRate+Qt`, `iV=-K r`, reduced `P r`
and every original residual, including exact selected source constraints. Both
left and right applications must have every coordinate interval wholly inside
original D, including every reconstructed selected current. In particular the
formal current interval [5,6] cannot admit reconstructed -2.25. The returned
residuals remain unresolved numerical obligations; containment does not certify
that any trajectory, root or physical current exists.

The private result retains original Values, left/right rate assumptions, source
SI slopes, charge-rate arrays, both original-plan Applications, closed smooth source
scopes and all admitted storage leases. Indexed access is checked; no arbitrary
public result constructor or replacement source-provider protocol is introduced.

## Runtime Flows

Scan/check the actual prepared inventory, admit fixed buffers, form tangent lifts,
consume each actual smooth borrowed range synchronously, close captures, apply the
original forest and check final domain containment before publishing. No borrowed
span crosses await. Source helper failures preserve primary and cleanup failures
and pending cleanup owners. No partial reconstruction is returned.

The shared internal spatial borrow requires an explicit query-domain choice:
`.lifted` derives the contained Values box for this reconstruction; `.original`
derives the full original D for the [mass consumer](../PrescribedVoltageMass/DESIGN.md).
No default domain or caller-supplied replacement box is accepted. Both consumers
use the same actual binding checks and close/cleanup path; only their explicitly
selected query and synchronous raw-plane action differ.

## State, Ownership, and Lifecycle

| State | Owner / isolation | Lifetime |
|---|---|---|
| Actual devices | Exclusive borrowed prepared circuit | Operation |
| Original Values/reduction/plan | Immutable retained value owner | Result copies |
| Work/floor/admissions | Original unconditional Mutex preparation control | Original and new reservation tickets |
| Tangent workspace | Original reduction, caller-isolated non-Sendable workspace | Operation |
| Smooth query | Actual snapshot and exclusive noncopyable capture | Close before success |
| Rates/applications/scopes | Private immutable result | Final reference release |

Reuse the original reduction Owner, not a new reduction merely sharing its control.
Checked capacities and explicit limits preadmit initialization/copy/storage before
allocation. Original cumulative control charges native terms, raw matrix products,
scans and copies; no budget reset or refunded work exists. No unsafe storage,
unchecked Sendable or target-specific synchronization is introduced. Managed
capacity/borrow evidence is not an allocator or zero-copy measurement claim.

## Failure, Concurrency, and Constraints

Typed failures distinguish wrong prepared binding, input shape, missing smooth
capture capability, capacity and final outside-original-domain row/side. Existing
native/reduction/range/cleanup/resource/cancellation causes propagate. Failed
operations refund temporary/result leases and leave the prepared owner usable
where its actual underlying lifetime remains open. Input reduced rates and U slopes
are assumptions; arbitrary source history and model calibration are not inferred.

## Verification and Change Impact

Actual C2/R4/phi=2U/T=2/U=.5 gives v=1, Q=2, F0=.25 and i=-2.25 for normalized
slope1; dropping the prescribed-input charge rate gives -.25. Distinct left/right
slopes distinguish side selection and time scaling. Original D must include the
computed current; [5,6] refuses. Floating/reversed multi-source trees check every
original row and source orientation. Actual smooth linear/parabola OSDI fixtures
check raw row/column aliases and nonlinear chain rule. Wrong owner/context/domain,
time input, nonsmooth source, current dependence, capacity/cancel/cleanup/refund and
retained lifetime tests own refusal behavior. Existing value-only and lower apply
arithmetic remains unchanged. One scoped review and necessary finding-limited
recheck own completion after focused runtime qualification.


Qualification on the frozen implementation: the Native focused scope passed ten
test declarations (11 argument cases, zero skips), including five new native
reconstruction declarations, three actual OSDI reconstruction declarations and two
existing value-retention regressions. Nine unchanged declarations passed in
`runtime-native-r1`; the one exact retained-lease baseline correction passed in
`runtime-native-refund-r2`. All production bytes remained unchanged. Smooth-range
bridge qualification is owned by the linked RangeExecution design. Stage receipts
and the complete source/fixture binding are retained under
`.verification/prescribed-voltage-reconstruction-20261020/`.
One comprehensive scoped review by `release_fix_export` closed with no concrete
finding; no recheck was needed. The qualification establishes only the conditional
rate/current/domain contract above, not roots, existence, flow, entire history,
explicit-time charge partials, source seams or full Sky130 source export.
