# OSDI Equation Execution

## Purpose and Scope
Child of [CoreSpiceOSDI](../DESIGN.md); this existing component owns all native
equation evaluation, shared session lifetime and analysis-specific contributions.

## Responsibilities and Boundaries
Implements its parent's adapter contract without owning physics or solver policy.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Adapter](../DESIGN.md) | parent | Equation adapter contract | Native-only | Revalidate native consumers |
| [Continuous equation structure](../../CoreSpiceDevices/ContinuousEquationStructure/DESIGN.md) | depends on | Package-only complete support visitor | Actual immutable mapping witness | No sampled support, rank or source-flow authority |
| [Devices lifecycle](../../CoreSpiceDevices/TransientLifecycle/DESIGN.md) | depends on | Explicit initialization, trial bound, physical residual | Accepted step belongs to Analysis | No history publication by a query |
| [Residual noise](../../CoreSpiceDevices/ResidualNoise/DESIGN.md) | depends on | Canonical source metadata and borrowed PSD | A/V/W residual excitations | Preserve source index and collapsed sources |

## Architecture
```text
setup -> fixed projection -> consuming binding -> exclusive evaluation
```

## Contracts and Invariants
The incidence P maps active circuit values to raw descriptor coordinates. DC uses
`A += P^T G P`, `b += P^T(GPx-F)`. Pure AC uses `P^T(G+j*omega*C)P` with no
device excitation RHS. Noise matrix uses the explicit native noise mode at the
same operating point. No charge is approximated by C*x.

`BoundOSDIDevice.poleZeroStampApplicability` admits this exact AC realization as
affine. `OSDIExecutionOwner.stampComplex(noise: false)` supplies fixed AC mode,
zero time, the same initial native slots and no frequency to native evaluation;
omega enters only the subsequent multiplication of C. The lower public context
rejects a frequency outside noise mode, and the native `OsdiSimInfo` evaluation
inputs do not contain omega. Thus at fixed bias the complete projected topology
has frequency-independent G and C, including explicit flow/thermal/private
coordinates. This contract concerns the implemented finite `G+sC` realization;
it does not qualify hidden frequency-dependent model physics or add an ACNQS
elimination. A future frequency-aware evaluation path must revisit this admission.
The dedicated OSDI binding tests verify the declared capability and the actual
three-frequency matrix relation for dynamic RC, context-sensitive AC and
flow/thermal fixtures.

Transient uses raw accepted Q and its accepted derivative Iq. BE defines
`Iq=alpha*(Q-Qaccepted)`, alpha=1/h. TR defines
`Iq=alpha*(Q-Qaccepted)-Iqaccepted`, alpha=2/h. Both stamp
`J=G+alpha*C`, `b=J*Px-F-Iq`; direct physical validation contributes `F+Iq`.
All raw contributions are checked for finite arithmetic before caller mutation.

Initialization is explicit TRAN|IC|STATIC at time zero for either the operating
point or UIC solution origin. It evaluates Q0 and candidate native state from the
supplied initial native slots. Q0 and that candidate become the run baseline.
Iq0=0 is the initial derivative convention, not a derivative inferred from C*x or
an invented prehistory. The first accepted interval must use BE; its exact charge
difference establishes Iq and permits subsequent TR, including variable steps.
These are DAE charge and native-slot transport guarantees, not a generalized
integrator for arbitrary hidden-state dynamics.

Native noise metadata is projected once through raw-to-active-to-canonical
coordinates. Endpoints must have one common admitted residual unit A, V or W;
ground contributes no coordinate and equal endpoints remain as cancelling
sources. Source indices, order and admitted original descriptor names are preserved;
equal names do not merge distinct indices. Immutable runtime string backing is
shared, with retained logical name bytes charged before projection. A synchronous density callback receives the
fresh same-call native PSD span outside all locks. Caller errors are restored and
re-thrown unchanged; no error is converted into zero noise.

`OSDIReactiveResidualProviding.hasReactiveResidual` is immutable descriptor
capability metadata, computed by OR over every admitted raw node's
`hasReactiveResidual` flag. Ground and collapsed raw rows remain in this union.
False means the descriptor advertises no reactive residual storage anywhere;
true is conservative and does not assert a nonzero value at any particular bias.
No sampled C value, Jacobian column or hidden-state inference contributes to this
fact. Native composition owns the whole-circuit LTE policy using this capability.
Manually constructed runtime nodes default conservatively to true.

Preparation bounds count and adapter bytes before allocation; runtime limits bound
native storage/workspace. Foreign evaluation and stamping execute outside locks.

## State, Ownership, and Lifecycle
Prepared owners are noncopyable. Bound references share only an exclusive checkout
owner; explicit close destroys evaluator buffers before unloading its image.

| Data | Owner and update |
|---|---|
| Supplied initial native slots | Immutable session baseline used for DC/AC/noise and each new run |
| Accepted Q/Iq/native slots/time | Session-owned fixed buffers; updated only after initialization or accepted-step fresh evaluation fully validates |
| Trial Q/Iq/native slots | Separate fixed buffers; arbitrary Newton/LTE/query evaluations cannot publish them |
| Accepted maximum timestep | Mutex control state; updated only with accepted history, nil means no bound |
| Ending request | Mutex control state; nonthrowing end clears idle history or requests clearing when the checked-out session returns |

Begin rejects a second run; DC/AC/noise reject an active transient run. A fresh
candidate-bound query evaluates the candidate against the same accepted baseline
and never updates history or the accepted bound. Acceptance re-evaluates the exact
candidate, rejects a bound smaller than h, validates all trial buffers, then swaps
buffers after borrowed native inputs have expired. Rejected steps need no restore
operation. End retains storage for reuse and prevents an in-flight operation from
leaving a run admitted; close remains an explicit busy/retry operation.

## Failure, Concurrency, and Constraints
Typed failure preserves native cleanup owners and primary/secondary errors.
No candidate state is committed by DC evaluation. Invalid integration, missing
run initialization, nonfinite arithmetic, invalid noise units/PSD, missing CSR,
native flags, reentry and use after close fail explicitly. Cancellation closes unpublished
owners; concurrent/reentrant stamp or close returns busy.

## Verification and Change Impact
[Adapter tests](../../../Tests/CoreSpiceOSDITests) verify this child contract.
Parent NativeExecution verifies circuit composition and completed result cleanup.

### Shared-state review matrix

| Target | Storage | Isolation | Read / mutation | Shutdown / owner release |
|---|---|---|---|---|
| Native | `Mutex<State>` holding optional noncopyable Session | Exclusive checkout and busy bit | `checkout` / `restore`; foreign calls use local session outside lock | model close, then image close; retry preserves session |
| Ordinary WASM | Native adapter unavailable | No alternate implementation | No raw-state fallback | Not qualified |
| Embedded WASM | Native adapter unavailable | No alternate implementation | No raw-state fallback | Not qualified |

The immutable execution reference never publishes model/storage pointers. Native
WASM/Embedded loading remains unavailable, with no weaker synchronization branch.
Whole-analysis completion and failure cleanup belong to NativeExecution; nested
operating-point validation must not close these owners.

The OSDI-specific residual protocol refines the generic device-owned
`DCPhysicalResidualContributing` contract with the same method requirement.
This preserves existing adapter callers while allowing native composition to
combine raw model equations and actual R/V/I equations through one public boundary.

S4 tests own AC/noise mode distinction, nonlinear charge BE/TR, one accepted BE
before TR, repeated trials/rejection and native-slot transport, candidate bounds,
noise callback throws and concurrent end/close. Independent same-artifact oracle
cases cover the actual four model families; no source physics is duplicated.

## S4D Compensated Model Composition

Precision is selected only by explicit preparation inputs. Ordinary DC/AC/noise
and nil-precision transient behavior retain the preceding contract. The bound
precise residual protocol refuses a missing precision owner; it never derives a
certificate from ordinary F/G/C. Model arithmetic is solely the lower
[precision runtime](../../../../swift-osdi/Sources/OSDIRuntime/PrecisionExecution/DESIGN.md).
Twofold enclosure operations are solely [Devices NumericalState](../../CoreSpiceDevices/NumericalState/DESIGN.md).

The mapping retains each typed active MNAVariable and its exact bound global
index. Precision gather uses `checkedBoundCompensatedValue(at:for:)` and validates
all paired storage; explicit ground contributes (0,0). Session-owned accepted
active high/low coordinates and their original context survive all rejected
trials. The existing unknown buffer holds candidate high components; three extra
active buffers hold candidate low and accepted high/low. Six extra raw buffers
hold accepted and trial Iq high/low/radius. These addresses/capacities are fixed.

Each model call receives candidate and accepted-reference coordinate pairs with
their own original contexts. Endpoint clocks are exact scheduler binary64 values
with low zero. The integration denominator is the exact normalized twofold
candidate-minus-accepted endpoint difference and must equal the supplied high/low
step pair. G/C midpoints are inexact Newton aids; they carry no acceptance claim.

BE forms enclosed `Iq=deltaQ/h`. TR forms enclosed
`Iq=2*deltaQ/h-IqAccepted`. `CompensatedEnclosure` propagates model radii, division,
TR history and summation rounding. The precise physical contributor supplies the
complete original `F+Iq` high/low/radius at every raw row, projected additively to
the bound global row. It never forms Q from C*x or subtracts rounded native Q.
Stamping uses the same model-owned G/C and a finite inexact alpha for iteration;
Analysis independently replaces the correction RHS and gates unchanged physical
tolerances using the enclosed original equations.

Initialization evaluates both endpoints under explicit native IC at time zero,
retains the represented initial coordinates/context, and establishes Iq0=0.
The first accepted interval must be BE. Every accepted commit freshly evaluates
the selected candidate, validates the bound and all trial enclosures, then swaps
Iq buffers and copies represented accepted coordinates after all borrows end.
Rejected/Newton/LTE/bound/physical queries publish no accepted history. End only
clears run history and preserves reusable owners. Worker errors are terminal,
never solver step-retry advice or ordinary-lane fallback.

```text
Mutex checkout -> paired gather -> helper F/delta-Q/G/C
 -> enclosed BE/TR + original physical contribution
 -> accepted commit only: publish represented coordinates/context/Iq
 -> restore Mutex ownership
close: precision helper -> ordinary model -> library (all I/O outside Mutex)
```

The same exclusive noncopyable Session remains under the existing Mutex checkout
contract; no I/O, callback, helper wait or close occurs while locked. Explicit
close preserves retryable lower cleanup errors. The existing nonthrowing end is
history-only. Tests discriminate sub-ULP coordinates/charge, both step methods,
rejection isolation, exact interval refusal, bound refusal, failure cleanup and
legacy ordinary behavior. Whole Native/API/CLI integration belongs to the parent.

C8 focused behavior is owned by `Tests/CoreSpiceOSDITests/OSDIPrecisionAdapterTests.swift`: real compound source-fold/sub-ULP history, explicit time/IC charge and bound, cold receipt admission, and terminal worker exhaustion. The context fixture is `Tests/CoreSpiceOSDITests/Fixtures/precision_context.va`; generated images remain ignored verification artifacts.

## Canonical Accepted-Step Equation Decomposition

The existing companion residual remains an admission gate. Native composition also
requires the independent canonical accepted-step residual on every row:
`Fn + alpha*(Qn-Qaccepted) + Faccepted` for TR, with no previous-F term for BE.
The device exposes actual static F and the unadjusted charge increment separately
through the Devices decomposition contracts. It never infers F from accepted Iq.
The ordinary lane uses the same binary64 native model; the paired lane uses actual
model F and delta-Q centers/radii under the retained endpoint contexts.

The session retains accepted/trial static F along with existing accepted/trial Q,
Iq and native slots. Initialization caches actual TRAN|IC|STATIC F at explicit time
zero. An initial-static query returns this cache only while the session remains at
that exact context, validating the supplied initial coordinates against the accepted
state. It never reevaluates the previous state in DC mode or reconstructs its clock.
Trial decomposition uses the current TRAN context and accepted native slots; it
publishes no history. Only the existing successful commit swaps all retained terms.
Ordinary accepted coordinates/context and paired F centers/radii have explicit
capacity admission. Tests cover source-mode/time-sensitive F, rejected queries,
failed evaluation and accepted-state transport; Native owns the additional global gate.

### Same-trial source facts for both original gates

The companion contributor evaluates the model once and, only after all raw terms,
callbacks and cancellation checks succeed, records owned raw source facts. The
ordinary record contains actual F/Q; the explicit precision record contains actual
F and model-derived delta-Q high/low/radius. Fixed candidate high/low buffers and
an exact integration/context key identify the record. No borrowed runtime view or
pointer survives its evaluation closure.

The OSDI and precision views borrow evaluator-owned output storage and are valid
only inside their evaluation callback. The next gate executes after that callback
returns, so it cannot retain the view, its spans, or any address/pointer into those
outputs. It explicitly copies scalar source facts into fixed session-owned buffers.
Candidate coordinates are copied separately because initial-F queries reuse the
gather scratch before the next gate. These necessary bounded copies preserve the
same source values and exact trial identity across the callback lifetime boundary.
This path is not zero-copy.

| Profile | Retained source-record Double payload | Scalar writes when the record is copied |
|---|---|---|
| Ordinary | `A + 2R` | `A` candidate-high plus `R` each actual F and Q |
| Explicit precision | `2A + 6R` | `2A` candidate-high/low plus `R` each F high/low/radius and model-derived delta-Q high/low/radius |

Here `A` is the admitted active coordinate count and `R` is the raw row count.
Since `A <= R`, the explicit precision record is bounded by eight node-sized
Double planes; ordinary needs at most three. Record/key headers are admitted
separately. No record buffer is allocated or resized per trial. A cancelled or
failed attempt may perform these copies, but cannot publish its key. Native charges
initialization once and the comparison/copy/arithmetic envelope before each use,
including failed attempts, to the same cumulative work owner. Qualification is the
actual per-instance foreign-request count of two gates changing from two to one
for a matching trial, with these retained bytes and copy costs included; it does
not assert allocation-free execution, zero-copy, or measured elapsed-time speedup.

```text
companion evaluation -> complete validated F/Q or F/delta-Q -> owned fixed record
canonical query -> exact coordinates + integration + contexts + accepted generation
                -> matching record consumed once / otherwise fresh same-profile evaluation
begin / commit / end / failure / cancellation -> invalidate record
```

The key compares every represented coordinate bit, method, current time, step,
previous step and their optional low components, actual current/reference contexts,
and accepted generation. Initial-F cache reads can reuse input scratch without
changing this independent key. Begin/commit/end invalidate even on failure;
successful publication advances the accepted generation. Queries never advance
accepted F/Q/Iq/native slots. Canonical consumption invalidates before callbacks,
so rejected global gates cannot leave a reusable record. A mismatching query uses
the existing fresh evaluation with unchanged arithmetic and precision capability.

Existing Mutex checkout isolates both the record and its counters on Native; no
conditional shared-state implementation exists on WASM/Embedded. Only fully
successful companion evaluations can populate the record. The owner counts actual
companion/decomposition foreign crossings for focused real-model regression tests.
Preparation admits the added fixed raw and active planes before allocation.
Native charges source-record initialization once and a conservative fixed
comparison/copy/arithmetic work bound per companion and canonical invocation to the
same cumulative transient budget; no second budget or numerical fallback is introduced. Candidate-bound and commit
fresh evaluations remain unchanged.


Focused verification: `OSDIBindingAtomicityTests` compares real dynamic-context
source outputs and counts both gate crossings (one for an exact shared trial,
two when coordinates/context differ), including cancelled/error retries and run
restart. `OSDIPrecisionAdapterTests` compares complete high/low/radius outputs
against a fresh worker evaluation and tests low-coordinate and context mismatches.
`OSDITransientSourceFactKeyTests` checks accepted generation, every integration
bit, optional-history presence, endpoint mode and signed-zero context bits.
`NativeCanonicalTransientGateTests` checks that companion and canonical added
work use one cumulative owner and stop before source callbacks at exhaustion.

### Continuous equation support witness

The actual BoundOSDIDevice visits every mapped active coordinate as READ and every
mapped raw row as both F/Q WRITE. This conservative inventory does not infer zeros
from sampled values or hasReactiveResidual. It reuses its immutable bound mapping,
retains raw aliases as repeated visits, omits only ground and preserves private
body, thermal and internal-flow coordinates. A mandatory caller checkpoint precedes every scanned coordinate, including ground.
Each visit includes the canonical
MNAVariable and actual global index; the upper consumer must join the complete
axis of the same plan and retain the actual device/owner. It is structural input
support, not a constitutive range/root/continuation certificate. The component
uses the shared [structure contract](../../CoreSpiceDevices/ContinuousEquationStructure/DESIGN.md);
OSDIContinuousEquationStructureTests owns this actual mapping/binding regression.

### Actual-Bound Conditional Identity Capture

The package witness on the actual bound OSDI value is owned by
[RangeExecution](../RangeExecution/DESIGN.md#approved-actual-bound-identity-capture-sprint).
It uses the immutable bound mapping and source snapshot; its separate identity
session never evaluates or commits this owner's native trial/accepted state.
The ordinary owner only validates availability through its existing exclusive
checkout, with no foreign call or helper startup under its Mutex.
