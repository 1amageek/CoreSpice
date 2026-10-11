# BSIM4 4.5.0 Physics and Simulator Adaptation

## Purpose and Scope

Status: original preparation and static numerical source intake implemented;
AC/frequency NQS is implemented; transient BE/TR/NQS services are implemented; noise spectra/integration are implemented. Parent:
[CoreSpiceBSIM45](../DESIGN.md). No children. This component owns exact physical
source intake, original equations and the private simulator ABI adaptation.

## Responsibilities and Boundaries

Import only the nested official 2005-07-29 release. Current 4.8.3 code is useful
for understanding callers, not for reconstructing earlier physics. The external
solver retains limiting, convergence, timestep choice and analysis scheduling.
Source provenance and permitted corrections are part of implementation identity.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Native boundary](../DESIGN.md) | parent | Exclusive opaque context and full local outputs | Kernel composition | All failure paths remain destructible |
| [Research](../../../docs/bsim45-research/RESEARCH.md) | coordinates with | Primary sources and observed counterexamples | Evidence for source selection | Physical file counts are not runtime coverage |
| [4.8.3 physics](../../CoreSpiceBSIM4/Kernel/DESIGN.md) | coordinates with | Adaptation technique only | Separate release | No automatic equation/fix transplantation |
| [Schema](../../CoreSpiceMOSContracts/Schema/DESIGN.md) | coordinates with | Role/kind/scale and correction identity | Typed input boundary | Original SC table has a verified defect |

## Architecture

```text
official zip -> nested BSIM450.tar.Z -> per-file hashes + original notices
 -> deterministic adaptation manifest
 -> b4set + b4temp + b4check + b4geo
 -> b4ld (static I, Q, derivatives implemented)
 -> b4acld (AC/NQS) / transient services (implemented) / b4noi (future)
 -> parent ABI's finite output checks and context-local diagnostics
```

## Contracts and Invariants

- Original model parameter defaults, Given bits, temperature, polarity, BINUNIT,
  per-finger geometry, LOD, WPE and supported selectors remain version-specific.
  Model bounds are resolver selection inputs; physical correction never selects
  a different bin or changes resolved coefficients.
- Compile setup, temperature, geometry, checker and DC/charge from the same
  source manifest; AC and noise intake use that same release. Pin the original constants, units and simulator-service
  semantics; reusing current compatibility constants without comparison is invalid.
- All changes are deterministic transformations with original/adapted hashes and
  a reason classified as symbol isolation, simulator ABI, bounded storage,
  diagnostics, exact-bias evaluation, integration, or explicit defect correction.
  Do not import the unapproved `bugfix_450_new.txt` wholesale.
- Correct `sc` table identity from SCA to the distinct SC selector, consistent
  with Appendix A, Chapter 14 and the original SC setter. Record this as
  `sc-selector-v1`, preserve original source hashes, and verify that scaled SC
  changes well-edge distance while SCA remains unscaled. This is an explicit
  correction, not a claim of bitwise agreement with the defective frontend.
- Original documented/nonfatal parameter regularizations emit bounded diagnostics
  and retain effective values in private prepared storage. Invalid selectors,
  nonfinite values, unsupported parameters and fatal checker conditions fail
  before publication. No silent fallback to a different release, mode or bin.
- The checker cannot depend on successful `fopen("bsim4.out")` to validate inputs.
  Redirect both messages and control flow to context-local failure/diagnostics.
  Preserve every fatal condition even when diagnostic capacity is exhausted.

## Runtime Flows

Preprocessing applies omitted release defaults once, including UD=`1e14`, then
temperature and geometry corrections. Width for physical channels is W/NF;
selection width remains owned by the explicit input profile. Bias-dependent
current and charge use the same local topology and analytic derivatives.
Do not collapse internal nodes or approximate AC NQS using DC capacitances.
NF is a finite real value at least one, not an integer-only count. Omitted exact
model dimensions receive the original 5um L/W defaults only here, never during
family selection. M remains an independent positive frontend parallel multiplier.

B45-4 native trial integration consumes an explicit caller-selected method/time
step; connecting the existing Analysis caller belongs to B45-6. Preserve
all original junction, gate-mid, intrinsic and q-deficit state contributions;
prepare once, trial many times, advance history only on accepted steps.
Noise preserves original source pairs/correlation and release constants; original
noise service primitives must have a pinned, independently tested implementation.
No external simulator process is part of production execution.

## State, Ownership, and Lifecycle

Every mutable original field, geometry pointer, history buffer and diagnostic
belongs to the parent's single context allocation. Private pointers remain inside
its lifetime. One context represents one model/instance/geometry, so original list
traversal cannot share mutable knots between separate X instances or runs.
Noise scratch and integration scratch cannot overwrite accepted history.

## Failure, Concurrency, and Constraints

Original allocation/free/logging/global task-job queries are adapted explicitly.
Noise intent comes from preparation conditions; immutable topology follows it.
All input sizes, casts, iterations, indexing and diagnostic writes are checked.
The context never holds a borrowed pointer across return. Its parent enforces
exclusive access; B45-4 adds owner-scoped generation-bound tokens; no new lock or platform branch
weakens the safe owner's common synchronization contract.

## Verification and Change Impact

Standalone original-source references cover both polarities; all mobility, CAP,
diode, body/gate/series, temperature, WPE/LOD and NQS modes accepted by the release;
representative temperature/body-bias/reverse-operation/geometry limits; and omitted
versus supplied values. Sky130's narrower enabled modes are a separate matrix.
The SC dispatch counterexample in the research record must become a corrected
behavior regression before executable admission. New source defects require a
specific physical counterexample, explicit correction identity and focused tests.

Proposed proof tolerances, fixed before fixture generation: original-reference
current `1e-13 A + 2e-7 relative`, charge `1e-23 C + 2e-7 relative`; derivative
tests use a central-difference step sweep and agreement plateau, with current
Jacobian `1e-10 S + 2e-4 relative` and charge Jacobian
`1e-20 F + 2e-4 relative`. Test all active rows/columns, conservation and aliases.
Reference tolerances are numerical comparison criteria, not foundry accuracy.
The parent owns Native C AC/transient tolerances; circuit-analysis thresholds
belong to their integration tests and must record units, oracle and error norm
before execution.
Original-spectrum references use `1e-32 V^2/Hz + 2e-7 relative` per channel for
explicit complex voltage gains, and integrated RMS voltage uses `1e-18 V + 2e-7
relative`. These proposed comparison thresholds start from the existing 4.8.3
proof policy, not a measured 4.5 accuracy claim; changes need a documented numerical
conditioning/error study rather than a passing-test target.

## B45-2 Source Intake

Compile only original parameter tables/setters, setup, temperature/check and
geometry in this unit. The adaptation generator records original/adapted hashes
and rewrites symbol namespaces, simulator services, fixed geometry storage and
context-local diagnostics. Remove file-opening as a guard around fatal checking;
check execution is independent of diagnostic capacity. Preserve formulas and
regularizations. Validate selectors before their original default-reset branches.
The SC selector correction is the sole table-semantic change.

Preparation proof tolerances are `2e-13 relative + 1e-20 absolute` for the
receipt's named SI scalar values; node aliases/counts are exact. They were fixed
before reference generation. The 648-case fixture explicitly supplies AT=0
across temperature modes, avoiding the invalid use of mode-0 default AT with
mode-1/2 temperature semantics. A separate fatal-path case preserves rejection
of that invalid combination. The SC analytical geometry identity is checked
independently of the original erroneous input table.

The original host constants used by preparation and their pinned SPICE3f5
authority are recorded in [NOTICE](../NOTICE.md). Checker diagnostics map to
original file/line sites in upstream.json. All checker control flow executes
when diagnostic capacity is zero; no filesystem state participates.

## B45-3 Static Source Intake

Add the pinned original `b4ld.c`. Simulator voltage limiting/bypass is disabled
at the exact-bias service boundary; the numerical solver owns those decisions.
The static NIintegrate path explicitly implements dQ/dt=0; B45-4 separately
owns nonstatic modes and history. Seed original bias-state slots
for MODEINITSMSIG, then evaluate MODEDCOP with zero integration coefficient.
Refresh bias-dependent NQS coefficients before the current stamp. Both loads
share the same prepared model, bias and fixed owner storage.

Project intrinsic G/D/S/B charges and analytic capacitances with the original
forward/reverse permutation. Add original gate-drain/source overlap, gate-bulk
overlap and junction charges as signed terminal pairs, including gate-mid and
separate drain/source body nodes. Original polarity changes charge signs and
voltage signs together, leaving capacitance sign unchanged. NQS deficit is not a
physical voltage or equilibrium charge; omit its relaxation row/column only at
the explicitly static ABI. Preserve original NQS coefficients for later units.
Use pinned SPICE3f5 CHARGE=1.6021918e-19 for original poly depletion, alongside
the existing preparation constants. Do not transplant 4.8.3 derivative repairs.

`Proof/verify_static.py` owns independently compiled unmodified-original static
references, full-node finite-difference step sweeps, physical row/column sums,
gauge shifts, n/p symmetry, bias-order independence and atomic input/kernel
failure. Current and charge tolerances above remain fixed before fixtures.
Every admitted selector is exercised, with explicit NQS equilibrium semantics;
AC/NQS dynamics, transient state and noise remain outside this proof.

### CAPMOD=0 Analytic Chain Rule Correction

The initial unmodified-source comparison agrees for all I/Q/G/C entries, yet
independent charge finite differences fail with NGATE=1e20 and nonzero body bias.
CAPMOD=0's dVdsat/dVg already includes poly-depletion's dVgs_eff/dVg; later
formulas apply that factor again. Its bulk/threshold derivatives also omit the
original smoothed body-voltage chain factor after overwriting Vbseff for the CV
argument. Correct derivatives only, preserving the original charge/current laws:
differentiate Vdsat with respect to Vgs_eff, apply poly depletion once at final
gate derivatives, and retain the original body factor for Phis and Abulk0 while
the CV argument has its own raw-body derivative. Record `cap0-chain-rule-v1` in
adaptation identity. Original-reference I/Q/G remain required; differing intrinsic
C entries require this explicit condition plus independent full-node finite
differences. Other modes/entries retain original-reference equality.

### Smoothed CV Drain-Voltage Body Derivative

Independent tests also expose CAPMOD=1/2 negative-T0 branch errors. For
VdseffCV = VdsatCV * T4 and T4 = 1 - 2*DELTA_4/(T1-T0), its partial body
derivative is dT0_dVb*T4 + T5*(dT1_dVb-dT0_dVb). The original uses 1-T5
instead of T4-T5. Correct this derivative without changing VdseffCV or charge;
record `cv-drain-body-v1` separately and require finite-difference proof.

### Coulomb Mobility Derivatives

The original mobility term UD*Vth^2/T3^2 has a bias-dependent numerator.
Its partial drain/body derivatives omit 2*UD*Vth/T3^2*dVth; MOBMOD=2 also
omits the TOXE conversion from its gate derivative. This is visible in the
bias-dependent gate resistor at low inversion. Add the numerator derivatives
for all three mobility modes and the MOBMOD=2 gate conversion, leaving mobility
and all current values unchanged. Record `ud-chain-rule-v1`; verify both the
channel and gate-resistor physical Jacobians by full-node finite differences.

Finite differences use seven central steps from 1e-2 to 1e-6 V and require two
adjacent passing steps at the fixed tolerances. At the forward-junction fixture
16/point4, a ~9 A body current has a ~5e-7 S gate derivative. The 1e-4 V and
smaller differences lose precision (FD 5.016e-7 down to 4.832e-7); the 1e-3 V
step gives 5.02325e-7 versus analytic 5.02353e-7. Wider steps establish the
plateau without increasing the absolute or relative tolerance. All smaller
steps are still computed and recorded by the same algorithm.

At exact signed VDS=0, the original law chooses forward orientation; its charge
law can have unequal one-sided slopes because threshold/body/drain dependencies
are recomputed after reversal. A unique two-sided derivative does not exist for
those entries. The ABI reports the analytic Jacobian of the selected forward
branch, preserving release physics. The zero-VDS fixture tests a three-point,
second-order one-sided difference for D/S columns within that branch, and central
differences for the remaining columns; all use the same plateau/tolerances.
Both nonzero directions are tested separately. This is not a smoothing change.


### B45-3 Verification Ownership

| Invariant | Proof owner | Counterexample detected |
|---|---|---|
| Exact static I/Q law and unaffected derivatives | `Proof/static_reference.c`, `verify_static.py` | Wrong polarity, overlap/body mapping, NQS substitution, later constants |
| Complete physical Jacobians | `Proof/static.c` | CAP0 gate/body chain, CV body smoothing, UD mobility numerator errors |
| Conservation and voltage gauge invariance | `Proof/static.c` | Missing row/column, wrong sign, charge duplication at aliases |
| Symmetry and zero-current equilibrium | `Proof/static.c` | Polarity projection; symmetry fixture explicitly disables polarity-dependent WPE and tunneling effects |
| No allocation/cold setup/history mutation | `Proof/static_ownership.c` | Repeated preparation, retained caller state, writes to accepted/older arrays |
| Atomic failure and terminal invalidation | `Proof/static_ownership.c` | Nonfinite result published, poisoned owner reused, partial release |

Fixtures combine 580 parameter/topology conditions and seven bias points,
including exact VDS=0, both polarities, reverse bias, accumulation/depletion/
inversion, temperatures, fractional NF, all admitted current/charge mode values,
BINUNIT 1/2, WPE on/off, source geometry modes and XPART-disabled intrinsic charge.
Geometry/noise selectors whose only behavior is preprocessing remain qualified
by B45-2; noise spectra and NQS dynamics are not qualified here. Static tests
execute the real public C entrypoint. The white-box ownership test additionally
uses arbitrary accepted/older history sentinels and fatal nonfinite biases.


Sanitizer verification executes all topology/bias fixtures, conservation, gauge
shifts, bias-order independence and ownership/atomic-failure paths. Full-node
finite differences execute separately in the release proof; repeating its
half-million perturbations under -O0 sanitizers adds no topology or ownership
coverage. The initial combined sanitizer run exceeded 60 seconds; the separated
memory proof retains all 4,060 operating points with a 30-second deadline.

## B45-4 AC Source and Independent Proof

Import nested original b4acld.c into the same namespaced target; preserve all
release topology, gate-current and NQS stamps. The parent owns physical-slot
projection and atomic publication. AC scratch CKTstates aliases the same owned
state arrays as CKTstate0/1/2. No history data is copied from caller buffers.

The original computes (omega*tau)^2 directly. Replace only relaxation factor
arithmetic with reciprocal forms when omega*tau > 1; compute omega*T3 without
an overflowing product. This preserves H=1/(1+j*omega*tau) for representable
results, including very large finite omega. Record `ac-nqs-stable-v1` separately.
All other AC equations remain exact original source until a concrete independent
counterexample establishes a correction. Original AC receives static coefficient
corrections already owned above; those are not new AC physics.

| Invariant | Proof owner | Counterexample |
|---|---|---|
| Original AC stamp | Proof/ac_reference.c | Wrong sign, pointer topology, release dispatch |
| QS Y=G+j*omega*C | Proof/ac.c | NQS selector leakage, missing static derivatives |
| Independent NQS H | Proof/ac.c | Wrong channel/charge relaxation or reverse permutation |
| Complex KCL/gauge | Proof/ac.c | Missing row/column or alias accumulation |
| History/resource/failure | Proof/ac.c | Accepted history mutation, reallocation, partial output |

Transient BE/TR and trial/commit lifecycle are qualified by the separate B45-4
unit; no callable placeholder is introduced. B45-5 noise has its independent qualification below; public adoption remains
B45-6. Propagate ABI changes to the parent and package status without
claiming these later contracts are implemented.

Sanitizer AC verification keeps all 580 topology/parameter conditions and seven
biases, using zero, 1e12 and DBL_MAX/16 rad/s. It checks order independence once
per bias, while the release proof checks all eight frequencies and order after
each. No ownership or topology branch is removed. Actual setup/temperature
functions are instrumented in the proof translation unit; each is called exactly
once per owner. Concurrent native compilation exceeded the original deadlines;
final verification is serialized, with 120-second compile and 60-second compact
sanitizer-runtime limits for AC. The retained full eight-frequency sanitizer
binary is additionally executed with a 120-second deadline, preserving its
source and artifact hashes instead of recompiling unchanged production sources.

## Transient Integration and History Ownership

[Parent transient contract](../DESIGN.md#b45-4-transient-contract) owns the ABI,
coordinates, lifecycle and tolerances. `transient_integration.inc` owns bounded BE/TR charge companions;
`transient_evaluation.inc` owns atomic history publication, trial tokens and augmented stamps.
It invokes original `b4ld` only in normal MODETRAN after explicit initialization;
MODEINITTRAN and predictor branches cannot mutate accepted history. Integration
admits only the original eight charge/current pairs (11,13,15,17,19,21,23,25).
Slots 0...10 are bias, 27 is deficit coordinate, and 28 is dependent source charge;
all 29 slots rotate on commit, including currently inactive slots.

`Proof/verify_transient.py` compares separate original-source processes (including
SPICE3f5 NIintegrate) and verifies independent charge companions, NQS relaxation,
compositional static/dynamic finite differences, conservation, exact history/token behavior,
allocation/setup counts and ASan/UBSan. This qualifies the C numerical boundary;
no full circuit solver or public 4.5 numerical coverage is inferred.

### Stable NQS Channel Charge

At low inversion CAPMOD=1/2 first compute channel charge and its derivatives,
then add/subtract the much larger accumulation/depletion charge to gate/bulk.
Reconstructing channel charge as -(final gate+bulk), and drain charge by another
subtraction, loses significant digits in the NQS partition quotient. Retain the
channel and source expressions before those cancelling additions; derive drain
and NQS derivatives from those retained values. Record `nqs-channel-charge-v1`.
This is an algebraically equivalent evaluation of the 4.5 law, not a new model
or threshold; raw reference differences remain subject to fixed I/Q tolerances.

The exact VDS=0 CLM branch excludes diffVds > 1e-10. At that boundary the
proof freezes only PCLM=0, the analytic extension of the selected CLM-disabled
branch. Center residual/Jacobian/all 29 states must remain byte-identical; all
perturbations retain forward orientation. PCLM is used only by the CLM branch
and is restored afterward. This avoids sub-1e-10 V numerical subtraction.

Derivative proof is compositional: static G is qualified by the independent
static current finite differences; transient proof differentiates nodal charge
companions and deficit relaxation separately and compares against augmented J-G.
Constant accepted-history terms have zero derivative. This avoids using a 9 A
junction or TR history offset to measure a 1e-7 S dynamic derivative. Public
trial states supply the charges; independently checked deficit-column physical
coefficients supply relaxation. All dynamic cells require two adjacent passing
fourth-order steps at fixed tolerances. Actual-history residuals, all 29 states,
and transitions are separately checked against raw original references and
independent companion/relaxation equations. No accepted bank is altered by this
conditioning and no production fallback or tolerance increase is introduced.

### Charge-Disabled NQS Derivatives

XPART<0 disables intrinsic charge computation and sets gtau=0 in the original
release; overlap/junction companions and deficit storage remain active. Original
forward/reverse NQS stamping nevertheless differentiates gcrg as if gtau were
nonzero. Set those voltage derivatives to zero for XPART<0, matching the retained
zero relaxation law, while preserving residuals and every state value. Record
`nqs-disabled-charge-derivative-v1`; verify all augmented finite differences for
this branch too. No QS fallback or new charge law is introduced.

## B45-5 Source and Service Ownership

The [parent noise contract](../DESIGN.md#b45-5-noise-contract) owns ABI, source
order, units, limits and failure policy. Import the exact nested b4noi.c
Eval1ovFNoise and local N_DENS branch before simulator traversal/integration.
Retain original copyright and per-file hashes. Names, plots, frontend jobs,
nVar integration and sweep buffers remain outside the device kernel.

`noise_primitives.inc` owns scoped thermal/shot pair projection using pinned
SPICE3f5 constants. Apply source power to normalized complex gain without first
squaring an unscaled huge gain; zero source power remains exactly zero. Flicker
source power is computed before gain projection, algebraically preserving the
original formula. `noise_evaluation.inc` owns atomic publication and topology
admission; `noise_integration.inc` owns the bounded stateless interval primitive.
The parent owns retained staging; each stack context borrows gains synchronously.
No change to static physics, accepted history or numerical solver is planned.

| Invariant | Violation detector |
|---|---|
| Exact 13 sources plus sum, both TNOIMOD/FNOIMOD values | Separate original noise process and per-source independent equations |
| Theta/beta partition and reverse gate-shot mapping | Both polarities/directions, mode isolation and analytic coefficient identities |
| Body networks and noise-only prime nodes | All body/gate/series modes, RBODYMOD=2 bodymode 1/3/5 given-bit cases |
| Complex gains and independent sources | Phase rotation/scaling, equal pair gains, source pair isolation, exact sum |
| Stable integral, flat/1/f/zero limits | Pinned original primitive plus analytic and high-precision interval integrals |
| Exclusive bounded lifetime and failure atomicity | Exact allocation/setup/release counts, all history/nVar bytes, pending tokens, malformed/extreme requests and ASan/UBSan |

### Low-Inversion Flicker Cancellation Correction

Independent trap-integral evaluation at fixture 0, VGS=-0.608 V and VDS=0.09 V
finds N0=0.00758102, Nl=0.0013838 and nstar=2.04847e15. Original
log((N0+nstar)/(Nl+nstar)) rounds to log(1)=0 and loses the finite trap-A
contribution. Replace it with log1p((N0-Nl)/(Nl+nstar)); factor the quadratic
difference as (N0-Nl)*(N0+Nl). These are equivalent original 4.5 expressions,
not a new trap law. Record `noise-flicker-cancellation-v1`. Independently factored
trap-integral tests use a relative criterion even far below the absolute raw
reference threshold; original comparisons retain their fixed tolerance.

### Frequency and Gain Scaling

A public regression with KF=0, FNOIMOD=0, EF=2 and finite DBL_MAX Hz has
finite, frequency-independent thermal/shot PSD. Computing freq^EF before
examining zero flicker incorrectly rejects it. The 4.5 flicker law is exactly
separable as S(1 Hz)*f^(-EF). Evaluate intrinsic flicker at unit frequency and
combine its logarithm, -EF*log(f), and normalized complex pair gain at final
projection. This also avoids an overflowing bare gain or frequency power when
the final PSD is representable. Record `noise-frequency-scaling-v1`. The
strong/weak harmonic combination uses min/(1+min/max), with explicit finite
nonnegative admission, instead of a product that can underflow. Zero powers
remain exact zero; unrepresentable positive final PSD is a typed failure.

### State Alias Classification

The generated finite-scalar checks exclude names shadowed by the original
header's state-index macros. `BSIM4qdef` expands to an integer bank offset, not
the unused identically named Double field. State-bank finiteness remains checked
at evaluation publication. This avoids classifying an integer as floating point
on WASI without casting or weakening physical-value admission.
