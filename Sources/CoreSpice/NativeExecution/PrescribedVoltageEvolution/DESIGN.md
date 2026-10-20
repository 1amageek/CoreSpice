# Prescribed Voltage Evolution

## Purpose and Scope

Child of [NativeExecution](../DESIGN.md), with no children. Own conditional
one-sided qDot/zDot, full original-row QDot and selected-source currents for one
actual matched prescribed-voltage chart. This is a finite closed-smooth profile,
not a trajectory existence, continuation, global cover or entire-history proof.
Status: finite conditional Native behavior qualified; the one scoped review is
closed with no blocking finding.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Actual prepared binding and original cumulative control | No new control or reset |
| [PrescribedVoltageChart](../PrescribedVoltageChart/DESIGN.md) | depends on | Private checked J/Y/qnorm, exact Z, original D, source scopes | Original CE proposal and center Values do not bound the expanded checked Z |
| [PrescribedVoltageValues](../PrescribedVoltageValues/DESIGN.md) | depends on | Original source laws, forest and native constant-law admission | Old Values.f is not used for evolution |
| [PrescribedVoltageReconstruction](../PrescribedVoltageReconstruction/DESIGN.md) | coordinates with | Full-row charge/current decomposition and original-D refusal | Its smaller-slab source queries are not repeated |
| [PrescribedVoltageReduction](../../../CoreSpiceAnalysis/PrescribedVoltageReduction/DESIGN.md) | depends on | Original plan/workspace/lift/apply | No fake zero state/input rates or replacement owner |

## Responsibilities and Boundaries

Current admission allows prepared native R/C constants and actual unselected Vdc;
unselected dynamic V refuses in Values. Existing source smooth capture rejects
explicit time input and seams. Thus explicit Qt and F0_t are zero in this profile,
by admission rather than inferred from samples. All selected source histories
remain explicit source-law/one-sided-jet assumptions; no PWL past clamp, phase
choice, slope narrowing or ordinary-waveform reinterpretation is added.

## Architecture

```text
actual chart construction: original identity + ONE full-original-D smooth query
    -> J and fused full-row F0 / local C / left-right CE and GE input actions
    -> checked chart with actual expanded Z and original source/control retention
same prepared owner + chart + explicit limits/cancel
    -> qDot and internally generated left/right forcing
    -> retained certified Y/q Neumann inclusion, preadmitted output buffers
    -> local C A zDot + cached C E phiDot on EVERY original row
    -> original forest.apply with checked expanded Z -> all current-D checks
    -> immutable conditional evolution result
```

## Contracts and Invariants

The package-only entry is synchronous, with no caller q, J, Y, forcing or rates:

```swift
package borrowing func reconstructPrescribedVoltageChart(
    chart: NativePrescribedVoltageChart,
    limits: NativePrescribedVoltageEvolutionLimits,
    cancellation: CancellationToken
) throws -> NativePrescribedVoltageEvolution
```

Limits have explicit positive `maximumRetainedBytes` and `maximumWorkspaceBytes`.
There is no new work quota or default profile; existing preparation/forest limits
and the original cumulative accountant remain mandatory.

The result has checked CE getters `chargeRate(at:)` (dynamic L index),
`reducedRate(at:side:)` (original reduced index), `fullChargeRate(at:side:)`
(original global row), `coordinate(at:side:)` (including reconstructed currents),
and `selectedCurrent(at:side:)` (original selected-source index). Dimension,
reducedCoordinateCount and chargeCoordinateCount are immutable. Side is the
existing `NativePrescribedVoltageReconstruction.Side`. No selected-current time
derivative is promised. Only a private complete constructor publishes success.

The immutable result additionally exposes package-only
`chargeStateLipschitzUpperBound: Double`. The matched chart supplies its retained
source-bound Kbar >= ||L P G A||inf. A synchronous helper scans that chart's
validated Y to bound its infinity norm, then computes outward
`Lq = Kbar * ||Y||inf / (1 - eta)`, where eta is the SAME checked
`||I - Y J||inf < 1`. Thus Dq(-L P F0)=-L P G A J^-1[I;0] is bounded for every
q/source parameter in this closed smooth chart. No detached Y, eta, Kbar or
caller derivative is accepted. The operation borrows immutable buffers under
the original owner check; it allocates no new output or scratch arrays, charges
each sparse slot/row and directed scalar operation, and retains the resulting
Double with the existing Evolution lease. Exact zero is preserved, positive
underflow stays positive, and nonfinite/overflow/invalid bound refuses.

This q-Lipschitz fact grants no time slab, initial set, trajectory, source-family
coverage or history authority. Existing left/right rates remain conditional on
the retained two jet assumptions. A future absolutely continuous input contract
must cover its measurable derivative almost everywhere; such derivatives need
not have left/right limits. Only an admitted a.e. derivative envelope could use
the corresponding chain rule/current bounds a.e. The current semantic API is
not changed to assert that admission.

An internal `chart.evolutionPayload(record:)` gate checks the same actual prepared
control identity. The payload exposes its concrete original control internally;
no detached q/J/Y/control certificate or caller callback enters this operation.
The numerical helper contract is:

```swift
internal static func enclose(
    record: NativeCircuitPreparationRecord,
    chart: NativePrescribedVoltageChart,
    rightHandSide: borrowing Span<CompensatedEnclosure>,
    into: inout MutableSpan<CompensatedEnclosure>,
    cancellation: CancellationToken
) throws
```

The caller preadmits and initializes k output cells and lends a synchronous safe
Array.mutableSpan. The helper allocates no output owner, never resizes/escapes the
span, and obtains only the matched chart's certified Y and qnorm. It computes
W=Yb and adds an outward infinity-norm tail q/(1-q)*maxabs(W). Exact zero cases,
positive underflow, overflow, nonfinite values and cancellation are explicit;
uncertified arithmetic cannot become a zero tail. This sufficient inclusion
uses the identical coordinate order and scaling of the checked J/Y.

Let P/A and B/L be the retained chart maps. For each admitted side:

```text
qDot = -L P F0
J zDot = [qDot - L P C E phiDot ; -B P G E phiDot]
QDot = C A zDot + C E phiDot
```

Strong B P Q=0 and admitted smoothness justify B P C=0. No Hessian or omitted
explicit-time term is hidden. Actual source laws compute each SI side as
(deltaV * normalizedSlope) / timeScale once; timeOrigin shifts time only.

Chart construction mandatorily fuses immutable spatial data into its existing
full-original-D smooth query: full-row F0, each source-local raw C array, full-row
left/right CE and GE actions, and the actual SI slope arrays. Native represented
terms and actual Vdc offsets join F0; both raw row/column aliases sum and ground
is scanned before global projection. Existing original-D identity and center
value queries remain separate prerequisites; Evolution performs ZERO new model
queries. The original Values.f and projected J alone are insufficient here.
All fused fields are bound to the same source/query/worker/profile/conditions.

The exact checked Z-to-CE coordinates already re-lifted and admitted by Chart's
P1 check are retained and used by forest.apply. Neither original proposal CE nor
a reboxed root.image is substituted. Full-row state and prescribed charge rates
remain distinct inputs to apply; only the profile-proved explicit Qt vector is
zero. Every final coordinate enclosure, including ALL selected source currents
on BOTH sides, must be contained in original D before publication. A chart may
qualify while this stronger current-section requirement refuses Evolution.

## State, Ownership, and Lifecycle

| State | Owner / isolation | Release |
|---|---|---|
| Fused F0/local C/input actions, checked Z and certified J/Y | Immutable Chart under its existing explicit retained cap | Last chart/evolution copy |
| Original work/storage/cancel | Existing unconditional Mutex preparation control | Original reservation tickets |
| Forcing, maps, source-zero tangent input and reusable forest workspace | Operation-local admitted buffers | Operation exit |
| qDot, two zDot/full-QDot arrays and two forest Applications | Private immutable Evolution, original tickets | Last result copy |
| Raw coefficients/inventory spans and zDot MutableSpan | Synchronous lexical borrow outside Mutex | Callback exit |

Chart retention is O(sum rawCount^2+n+k+sourceCount): local C is retained rather
than a dense global C. Input G is reduced to the required full-row actions;
Evolution does not retain/requery a redundant full G. Already-owned chart storage
is retained by reference, not charged a second time.

Evolution precomputes checked simultaneous capacities before allocation. Its
retained ceiling includes its own payload/vectors and both lower Applications;
each actual owner reserves its portion exactly once. Its workspace ceiling
includes forcing/maps, original 3n forest workspace, one-side tangent lift and
all simultaneously live scratch. Lower forest caps are honored, never enlarged
by replacing the reduction owner. Work charges initialized/copied cells, every
sparse product including zeros, both side actions, original-row scans and tail
arithmetic. Shared chart arrays are immutable; mutable outputs are unique local
arrays, with no span/pointer across await or Sendable boundary. No new unsafe or
target-dependent synchronization path is introduced. Logical capacity and actual
allocator/RSS measurements remain distinct claims.

## Failure, Concurrency, and Constraints

Wrong prepared owner, invalid capacities, nonfinite/overflow/tail failure,
original work/storage/cancellation, forest failure and current-D escape remain
typed refusals with no partial result. Reuse the existing reconstruction
outsideOriginalDomain(row:side:) refusal for all-coordinate containment. Source
helper cleanup remains owned by chart construction; Evolution has no foreign
I/O to reopen or close. Result inspection remains valid while its chart/leases
are retained, including after the original model owner is closed.

## Verification and Change Impact

Native discriminator: C2(d,p), R4(d,ground), R4(x,p), C3(p,ground), prescribed p=phi.
At phi=1,q=0, d=x=1 and qDot=-.25. DeltaV2/timeScale2 with normalized side slopes
1/2 gives dDot=.875/1.875, xDot=1/2 and iSource=-3.25/-6.25. Dropping CE yields
wrong dDot=-.125; dropping GE yields wrong xDot=0. C3 is absent from reduced J
but essential to full source current. Tight original current sections must
refuse, and source/quota/cancel/final-copy refund tests use the actual owner.

Actual tests reuse the qualified mixed linear source chart with narrow padded
point-parameter cells so interval inclusion also discriminates omitted terms;
no point result is inferred from a broad interval chart. Source images/compiler
are unchanged. Numerical helper tests own outward tail/matvec edge cases.
Fused chart retention changes require new native and actual Evolution tests plus
ONE affected .19 native-five/actual-four regression. Unchanged GlobalChargeKernel
and lower checker evidence remains valid. Root owns one combined scoped review,
one necessary finding-limited recheck and the coherent commit. The pure Native
fixture additionally records managed peak/work/refund for 512 diagonal charge
axes. This is a logical payload budget check, not an allocator or speed claim.

The q-Lipschitz extension additionally requires scalar directed-bound zero,
subnormal, near-unit eta, overflow and refusal checks, plus same-J/Y actual
source conductance changes and retained-owner/control/refund checks. No extra
model evaluation may be introduced. The extension and affected chart/evolution
regressions pass in the finite qualification below.

The q-Lipschitz extension is qualified by
[qualification-r5.json](../../../../.verification/validated-picard-slab-20261020/qualification-r5.json):
26 Native declarations and 18 Analysis declarations, zero skips, with one scoped
review closed. Ten unchanged Native declarations passed at r2; the corrected
actual-source declaration and 15 affected Native declarations passed at r4.
Only test expressions changed after the initial production snapshot. The failed
bitwise-image fixture premise remains recorded: raw Q interval accumulation can
change H0 images despite equal J/Y. All three final source cases require equal
actual J/Y/eta and contain the independent dyadic root; the first two equal-Q
cases additionally retain exact-image equality. Kbar bounds 2/2.5/3 still reject
dropped dynamic G or alias contributions.

The actual Lq helper consumed 17 work units and made no additional reservation.
The 512-axis Evolution case measured 226,224 managed peak bytes, 47,525 work units
and 135,720 retained bytes, followed by complete refund. These are operation-local
logical accounting results; they exclude prior chart construction and its row-sum
scratch. They are neither allocator/RSS bounds nor a speed or zero-allocation
claim. Common source-family admission, physical initial roots, slab composition,
global cover, continuation and complete history remain unproved.


Qualification is bound by
[aggregate-final-r4.json](../../../../.verification/prescribed-voltage-evolution-20261020/aggregate-final-r4.json):
22 unique declarations, zero skips (13 new and nine affected Chart declarations).
Nineteen unchanged declarations passed at r2; all three actual Evolution tests
passed at r3 after ending the two prepared-owner lexical scopes before the
unchanged final-refund assertions. The r1 ambiguous test-location compile failure
and r2 premature-refund failures remain preserved, without changing production
or numerical predicates. The
[one scoped review](../../../../.verification/prescribed-voltage-evolution-20261020/scoped-review-r3.json)
closed without a blocking finding; its admitted O(k) write-only algebraic map was
retained as a nonblocking minor without another source/test cycle.

The 512-axis/native-514-row case measured 226,216 bytes of additional managed
peak, 47,519 cumulative work units and 135,712 retained bytes, with final refund.
The two-axis inverse helper used 15 work units and zero additional reservations.
These are logical accounting measurements on the fixed Native Swift 6.4/macOS
SDK27 execution path, not allocator/RSS limits or a speed claim. Actual one-sided
CE/GE forcing, full-row charge/current contributions, both current-D refusals,
owner/cap/work/cancellation and retained-copy release were exercised. This
qualification does not establish complete chart cover, all-phase/history
continuation, actual56 precision export or production release readiness.
