# CoreSpice BSIM4 4.5 Native Kernel

## Purpose and Scope

Status: B45-2 preparation and B45-3 static I/Q/Jacobians are implemented in
independent SwiftPM C target `CoreSpiceBSIM45`. B45-4 AC/frequency NQS and BE/TR/transient NQS are implemented in the same target. B45-5 noise spectra and interval integration are
implemented; safe-owner/public execution adoption remains proposed and unavailable.
Parent: [CoreSpice](../../DESIGN.md). Child: [Kernel](Kernel/DESIGN.md).
It exposes an independently buildable exact-release preparation/static/AC/transient/noise C boundary. It owns no
parser, model search, expression evaluation, circuit compiler or solver.

## Responsibilities and Boundaries

This module owns the opaque C ABI, typed status codes, fixed output layouts and
the exclusive context lifetime. Its child owns original 4.5.0 equations and their
simulator adaptation. Symbols use `cs_bsim45_*`, including internal upstream
renames, so simultaneous 4.5/4.8.3 linkage cannot select the wrong function.
No dependency on the 4.8.3 target is permitted. Shared semantic contracts live in
portable MOSContracts; neither C target imports Swift or Foundation.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Target registration and unit dependencies | Independent native C build | Design is not capability |
| [Kernel](Kernel/DESIGN.md) | child | Source identity, equations, state and bounded preprocessing | Exact release implementation | No 4.8.3 fallback |
| [Safe owner](../CoreSpiceCompactModels/BSIM45/DESIGN.md) | used by | Exclusive borrowed C ABI | Synchronized Swift facade | Caller serializes every operation and destroy |
| [Schema](../CoreSpiceMOSContracts/Schema/DESIGN.md) | coordinates with | Release/parameter semantic identity | One admission authority | C admission cross-checks generated IDs/kinds |
| [4.8.3](../CoreSpiceBSIM4/DESIGN.md) | coordinates with | Ownership pattern only | Separate implementation and capability | Do not copy later defaults, warnings or fixes |

## Architecture

```text
checked numeric parameter IDs + explicit temperature/capabilities/work limits
 -> cs_bsim45_create -> original setup/temperature/check -> frozen topology
 -> static I/Q/Jacobians (implemented)
 -> complex AC/NQS | transient trial/reject/commit | noise spectrum (implemented)
 -> finite checked output publication
 -> cs_bsim45_destroy
```

The public C header belongs in `include/`; production C implementation belongs
in `Kernel/`. Selected original source files are compiled directly by this target.
No external SPICE engine is needed for build, link or runtime.

## Contracts and Invariants

Preparation, static, AC/NQS, transient/history and noise APIs are implemented. Release and adaptation identities are immutable
and queryable independently of a successful numerical run.

| ABI operation | Guarantee / failure boundary |
|---|---|
| `cs_bsim45_owner_size` | Exact same-build `sizeof` requested by create; no allocation, no allocator-overhead claim |
| `cs_bsim45_create` | One zeroed exclusive owner or allocation failure; exact 4.5.0 plus explicit schema/adaptation IDs |
| `cs_bsim45_set_model`, `cs_bsim45_set_instance` | Separate generated parameter ID/kind admission; supplied bits preserved; finite/range checks precede C casts |
| `cs_bsim45_prepare` | Single setup; caller-selected noise intent and work budget; publishes topology only on complete success |
| `cs_bsim45_evaluate_static` | Physical static I/Q and full analytic Jacobians; selected-branch derivative at VDS=0; atomic finite output |
| `cs_bsim45_evaluate_ac` | Atomic finite physical admittance with explicit angular frequency and frozen ACNQSMOD |
| `cs_bsim45_evaluate_transient` | Exact local bias and separate deficit coordinate; full augmented residual/Jacobian and 29 trial states; explicit BE/TR and dt |
| `cs_bsim45_initialize_history`, `cs_bsim45_commit`, `cs_bsim45_reject`, `cs_bsim45_history` | Explicit equilibrium initialization; exclusive accepted/older banks; owner/generation-bound token commits once or is rejected; inspection is nonmutating |
| `cs_bsim45_noise_spectrum` | Full local complex transfer gains borrowed for call; release-specific PSD slots and atomic publication |
| `cs_bsim45_integrate_noise` | Stateless adjacent-spectrum integration; source powers and RMS; no owner or sweep state |
| `cs_bsim45_destroy` | Exactly-once release, including any partial preparation state |

ABI statuses distinguish release/schema/parameter/state errors, allocation/resource/
diagnostic capacity, kernel/nonfinite evaluation, and invalid history. Cancellation
admission belongs to the caller; reject discards a pending trial. No partial output
is authoritative on failure.
Version and polarity are constructor-owned selectors, not writable numeric
coefficients. Store the canonical original version using owned/static storage;
never retain a temporary caller C string. Admission rejects attempts to overwrite
those selectors through either parameter buffer.
Diagnostics carry structured code, parameter/role and bounded values; formatting
and source-position attachment belong to the safe/preparation layer.

Ground plus at most twelve non-ground local slots are admitted: four terminals,
drain/source prime, gate prime/mid, body prime, drain/source body and q-deficit.
Aliases remain explicit. Original `bsim4def.h` defines 29 state slots and fourteen
noise channels. A 13-slot local result can therefore use 169 complex matrix cells;
tests must prove all creation paths fit before these become ABI constants.
The Swift wrapper may pad to SIMD16/SIMD32 and stride 16; C remains release-owned.

## Runtime Flows

Preparation consumes already evaluated SI inputs. It copies parameter values into
private original model/instance storage, applies release defaults and temperature
preprocessing, then freezes topology. It never modifies resolved input buffers.
Repeated bias evaluations never call setup, reinterpret names or reapply input scale.
Unsupported requested capabilities fail before prepared topology publication.

Transient trials preserve accepted and older state. Rejection/any subsequent
evaluation invalidates the old trial token. Acceptance verifies owner generation
and commits once. DC/AC/noise cannot mutate accepted history. The upper bound owner
keeps accepted-bias evaluation and commit within one lock sequence.

## State, Ownership, and Lifecycle

```text
allocated -> admitting -> preparing -> prepared
                              prepared -> initialized -> trial -> commit/reject
    |            |           |           |         |
    +------------+-----------+-----------+---------+-> destroyed
                              failure: never reuse partial preparation
```

One preparation allocation contains model, instance, one geometry knot, topology,
matrix, three 29-state banks, trial authorization/result staging and bounded
diagnostics. Redirect original geometry
allocation to that owner; all original pointers borrow owned storage. No retained
caller pointers, mutable process-global state, filesystem logs or callbacks.
The ABI is exclusive rather than internally locking. B45-6 must supply the
same safe-owner Mutex contract on every target. Current C callers serialize
all operations themselves; destroy cannot race any context operation.

## Failure, Concurrency, and Constraints

Caller budgets cover owner bytes before create, diagnostic bytes, preprocessing
work and temporary projection capacity. LOD loops preserve original fractional
NF semantics and account for `ceil(nf)` only when activated. Overflow is a failure
before iteration/allocation. Fixed topology and state arrays allocate nothing per
bias evaluation. Deterministic bounded calls check cancellation before/after at
the Swift boundary; work limits bound the longest uninterruptible native call.

## Verification and Change Impact

[Proof/verify.py](Proof/verify.py) owns current original setup/defaults, topology modes,
779 compiled-table checks, 648 independent original-reference receipts, 96
topology combinations, exact allocation/failure/release counts and ASan/UBSan.
Simultaneous 4.5/4.8.3 linkage prepares and destroys independent owners. [Proof/verify_static.py](Proof/verify_static.py) owns current full-node I/Q,
original references, finite differences, conservation and static ownership.
[Proof/verify_ac.py](Proof/verify_ac.py) owns AC/NQS. [Proof/verify_transient.py](Proof/verify_transient.py) owns BE/TR/transient NQS,
history/token behavior and ASan/UBSan lifecycle/failure paths.
[Proof/verify_noise.py](Proof/verify_noise.py) owns source spectra, integration,
complex projection and bounded noise lifetime. Each implementation unit builds and
executes only this target's needed sources, with a subprocess timeout. They do
not require GPU, parser, PDK or a whole package test build.

Unadapted nested 4.5 source in a separate process supplies differential fixtures;
both harness source and archive hashes are recorded. Independent conservation,
derivative and analytical limiting-case tests prevent adapter/oracle shared bugs
from being treated as correctness. The explicit SC correction uses manual-based
tests and cannot use buggy table dispatch as its oracle.
Changed ABI/defaults/topology/history require safe-owner and Devices revalidation.
Native CPU qualification is separate from portable schema runtime evidence.

## B45-2 Preparation-Only Implementation Contract

B45-2 implements create, typed numeric/vector admission, prepare, prepared
inspection and destroy; B45-3 adds static evaluation, B45-4 adds AC/transient and B45-5 adds noise operations specified below. A failed setter or prepare
poisons the owner; inspection publishes prepared values only after success.
Repeated preparation is a state error. The constructor admits owner byte budget,
diagnostic record capacity, temperature, polarity, noise topology intent and
LOD iteration budget before allocation. A single fixed allocation owns all
storage. Diagnostics use bounded structured records (code, role, parameter ID,
value and source-site ID), with optional bounded formatted kernel text; exhaustion
fails preparation without disabling original fatal checks. Caller serialization
covers every API call and destruction. No cancellation callback is retained; the
caller checks cancellation around the bounded synchronous call.

The preparation inspection receipt includes canonical release/adaptation identity,
actual node aliases, original state count, physical dimensions, defaults and
effective temperature values for independent proof. It is not numerical evidence.
Native Devices continues rejecting 4.5 numerical requests until B45-6 adoption.

## B45-3 Static Evaluation Contract

`cs_bsim45_evaluate_static` consumes exactly thirteen local voltage slots, ground
zero, unused slots zero and finite gmin >= 0. It returns physical nodal currents
(positive into the device), equilibrium nodal charges and row-major dI/dV and
dQ/dV in A, C, S and F. Existing topology aliases accumulate, not duplicate,
contributions. The NQS deficit slot is not a voltage/physical terminal: require
zero input and publish zero row/column there. NQS-enabled prepared models expose
the same equilibrium charge law; dynamic deficit equations belong to B45-4.
This operation provides no complex frequency matrix or history commit.

```text
prepared -> validate bias -> original exact-bias small-signal + DC load
         -> original intrinsic/overlap/junction charge projection
         -> finite output validation -> one output copy -> prepared
kernel/nonfinite/diagnostic failure -> terminal failed owner -> destroy
invalid caller input -> unchanged prepared owner, unchanged output
```

The existing allocation additionally owns bias/RHS and a result staging buffer.
Every original pointer borrows it; evaluate performs no allocation or setup, does
not retain caller input/output, and never writes accepted/older state arrays.
The caller exclusively borrows the owner and output, and borrows input for the call. Fixed bounded native
work is two original loads and constant-size projection; cancellation stays at
the caller's before/after boundary. No new shared mutable storage is introduced.
The adaptation identity changes when physics or projection changes. Full local
conductance is the original DC stamp; capacitance is an explicit projection of
original analytic intrinsic, overlap and junction derivatives, not finite
differences or an AC approximation. Full static original references, independent
conservation/gauge invariance and central-difference step sweeps own this contract.

At exact signed VDS=0, the release selects forward orientation. Its charge law
can have unequal one-sided slopes; the returned Jacobian differentiates the
selected branch. Tests preserve that branch for D/S finite differences.
Explicit derivative corrections and their proof are owned only by
[Kernel](Kernel/DESIGN.md#capmod0-analytic-chain-rule-correction); original current
and charge laws remain unchanged. No foundry accuracy certification is implied.

## B45-4 AC and Frequency NQS Contract

`cs_bsim45_evaluate_ac` borrows thirteen physical voltages, finite gmin >= 0
and finite angular frequency omega >= 0 (rad/s). It publishes row-major real
and imaginary admittance in siemens. All static input/topology rules apply.
The transient deficit slot is not a voltage: its input and published row/column
are zero. The original AC-only isolated unit diagonal on that nonphysical slot
is excluded from this physical projection, independently of ACNQSMOD.

```text
prepared -> validate complete request -> static operating-point coefficients
 -> QS: static G+j*omega*C; NQS: original b4acld with owner-local matrix
 -> physical projection -> finite validation -> single output copy
invalid input -> unchanged owner/output
kernel/nonfinite failure -> terminal owner; unchanged caller output
```

The operation consumes the existing static coefficient path and performs one AC
stamp; no allocation, setup or accepted/older history write is permitted. State0
is scratch; states1/2 are accepted/older history. Result staging belongs to the
single allocation and is included in owner_size, not charged again per call.
Input/output pointers live only for the exclusive synchronous call. No new
shared state or target-specific synchronization is introduced.

QS must equal static G+j*omega*C, including aliases, gate/body/series networks
and either transient NQS selector. AC NQS relaxes channel conductances and
source/drain intrinsic charges by H=1/(1+j*omega*taunet), retaining bulk,
overlap and junction contributions. At zero frequency it reduces to static G.
The kernel owns stable relaxation factors without squaring a large omega*tau;
negative/nonfinite relaxation time is a terminal nonfinite physics failure.
Large finite frequencies whose final admittance overflows also fail atomically.
AC does not integrate or commit transient history.

Proof/verify_ac.py owns raw original and coefficient-isolated AC comparisons,
QS identity, independent complex relaxation, row/column conservation, frequency
and bias order independence, arbitrary history sentinels, exact allocation,
invalid requests and terminal failure under ASan/UBSan. Raw original derivative
differences remain restricted to the child-owned documented correction footprint; the
coefficient-isolated oracle uses the unmodified original AC source and the
already independently qualified static coefficients, with no difference waiver.
Native CPU only. AC tolerance is 1e-12 S + 2e-6 relative per cell, fixed by the
package design. Changes invalidate this proof and actual C-import SwiftPM runtime.

### QS Frequency-Amplified Cancellation Correction

Independent QS tests at omega=1e100 and DBL_MAX/16 detect nonzero original
imaginary entries where the qualified final C is exactly zero, and discrepancies
above the fixed tolerance in tiny active entries. Multiplying each capacitance
before summing amplifies rounding error. `ac-qs-authority-v1` constructs QS from
the final qualified static G/C directly, giving one derivative authority and
exact floating-point Y=G+j*omega*C for every representable result. Original AC
remains the NQS stamp authority. The coefficient-isolated original comparison
covers omega 0 through 1e16 without waivers; extreme relaxation factors are
independently checked against 100-digit Decimal arithmetic over 36 cases.

## B45-4 Transient Contract

Native C only; public Swift/Devices adoption remains B45-6. The owner retains
three complete 29-double banks: scratch trial, accepted, and older. Initialization
qualifies exact equilibrium bias with the static service and zero integration
coefficients, then atomically copies all 29 finite states to both history banks.
Initialization has zero deficit and zero charge currents. It does not use the
original MODEINITTRAN branch, which writes accepted state during evaluation.
Normal MODETRAN and the bounded integration service write only scratch state.

```text
prepared -> initialize -> history ready -> evaluate -> trial authorized
                              ^            |             |
                              |         reject/new call  commit
                              +--------------------------+
```

Physical bias contains 13 voltages with ground/unused/charge slots zero. A separate
finite deficit coordinate supplies the charge node: physical deficit is
polarity * coordinate * 1e-9 C. QS requires coordinate zero. The result is the
full augmented residual (A) and its Jacobian, including the deficit equation;
physical columns differentiate volts, deficit column differentiates the scaled
coordinate. This is not the DC/AC physical-only projection.

BE uses a0=1/dt and dq=a0*(q-trusted_q); trapezoidal uses a0=2/dt and
 dq=a0*(q-trusted_q)-trusted_dq. Method and finite positive dt are explicit;
nonfinite reciprocal coefficients are refused. Each successful commit shifts
all 29 accepted states into older and all 29 trial states into accepted exactly
once. Time-step selection, startup method, convergence, and cancellation are
caller policy. Reject provides cancellation cleanup before commit; callers hold
exclusive access across their final accepted-bias evaluation and commit.

Every initialization/static/AC/transient attempt invalidates pending authorization,
even on invalid input. Invalid caller input changes no history or output. Internal
kernel/nonfinite failure is terminal and also preserves history/output. Inspection
copies accepted/older history and never invalidates a trial. Tokens pair a live
owner address with a checked nonwrapping generation; cross-owner, stale, rejected,
and double commits fail with HISTORY and do not change either bank. Native tokens
must not outlive their owner. B45-6's retained immutable identity marker separately
prevents address-reuse aliasing across destroyed owners. No mutable global ID exists.

One owner allocation includes all retained and scratch bytes, queried before
admission; no evaluate/commit allocation, setup, or temperature preparation.
Proof tolerances fixed before fixtures: residual/reference 1e-12 A + 2e-6 relative,
Jacobian/reference 1e-10 (physical column S; scaled deficit column A/coordinate)
+ 2e-6 relative; independent finite differences 1e-10 + 2e-4 relative;
state charge 1e-23 C + 2e-7 relative, state current 1e-12 A + 2e-6 relative,
bias/deficit coordinate 1e-13 + 2e-7 relative. Conservation uses sum-of-magnitudes
roundoff bounds. Original comparisons retain only the child-owned documented static/NQS derivative
corrections, each independently differentiated. Lifecycle checks are byte exact.

Each exact-bias evaluation seeds scratch bias slots 0...10 and deficit slot 27
from the current request. Accepted bias slots remain historical evidence, not
Newton-policy input. Otherwise original limiter scaffolding can choose a
roundtrip subtraction according to the previous orientation even when the
limiter function itself returns its input. This removes that history-dependent
roundoff without changing solver policy or the 4.5 physical law.

## B45-5 Noise Contract

Native C only; Swift safe-owner and public Devices/Analysis composition remain
B45-6. `cs_bsim45_noise_spectrum` consumes the same thirteen physical bias slots,
finite gmin >= 0, frequency in Hz strictly positive, and thirteen complex
output-voltage transfer gains (V/A). Ground, unused and deficit gain slots must
be zero. Preparation must explicitly request noise topology. Changing that
intent requires a new owner; evaluation never performs setup.

The spectrum contains frequency and fourteen V^2/Hz entries in the release's
exact order: RD, RS, RG, RBPS, RBPD, RBPB, RBSB, RBDB, ID, flicker, IGS, IGD,
IGB and total. There are thirteen stochastic sources and one sum, not fourteen
independent generators. BSIM4.5 has no additional induced-gate correlated source
or cross-spectrum output. TNOIMOD=1 includes its original theta/beta partition
effects in series and channel noise. Never import 4.8.3 mode 2 or NevalSrc2.
Complex pair gain is |H_positive-H_negative|^2, preserving phase within each
pair. Independent source powers are summed once; a total is never reinjected.
Constants use the pinned SPICE3f5 host definitions, including Boltzmann
1.3806226e-23 J/K and charge 1.6021918e-19 C.

```text
noise-prepared owner + validated bias/frequency/gains
 -> qualified static coefficients -> original N_DENS equations
 -> scoped pair-gain projection -> finite nonnegative source/total validation
 -> atomic spectrum publication
caller-owned adjacent spectra -> bounded interval integral -> caller-owned sum
```

All calls require exclusive access. Every spectrum attempt invalidates pending
transient authorization, even invalid input. Accepted/older 29-state banks and
original noise history nVar remain unchanged. Caller arrays are borrowed only
for the call; no gain pointer is stored in the owner. One owner allocation
includes spectrum staging and is queried by owner_size; fixed stack work and
allocator metadata are separate from retained payload. No per-frequency
allocation, setup, temperature preparation, callback, file or global state.
Invalid caller inputs preserve output/history and the prepared owner; a missing
noise topology has a separate status. Invalid physical coefficients, negative
PSD or nonfinite final output terminally fail without partial publication.

`cs_bsim45_integrate_noise` is a stateless, bounded two-endpoint service, not a
sweep owner. Frequencies must be finite, positive and strictly increasing;
spectra must be nonnegative finite with an exact ordered source sum as total.
For strictly positive endpoints integrate the unique log-log power-law
interpolant, including flat and 1/f limits; stable endpoint-anchored arithmetic
avoids the original primitive's cancelling powers. If either endpoint is zero,
log interpolation is undefined: the explicit contract is linear PSD on that
interval (two zero endpoints integrate to zero). No N_MINLOG floor creates
physical power. Integrate thirteen sources separately, sum total power (V^2)
and report sqrt(total) Vrms. Caller owns sweep storage, accumulation, input
referral, frequency policy, cancellation and resource admission. The service
retains nothing and never accesses a device owner or transient token. Invalid
inputs or unrepresentable positive results leave caller output unchanged.
This does not change existing NoiseAnalysis's trapezoidal integration policy.

Proof owners: `Proof/noise_reference.c` compares untouched nested 4.5 N_DENS
with unmodified pinned SPICE3f5 NevalSrc/Nintegrate in separate processes.
`Proof/noise.c` independently checks each source's thermal/shot/flicker formulas,
TNOIMOD=1 partition, body topology suppression, complex phase/scale identities,
source sums, integration limits/refinement and history/token/resource failures.
`Proof/verify_noise.py` records fixed source hashes, deadlines and ASan/UBSan.
Reference PSD tolerance is 1e-32 V^2/Hz + 2e-7 relative; interval RMS tolerance
is 1e-18 V + 2e-7 relative. Independent identities use relative/roundoff bounds
with explicit units. Original integral comparisons cover positive resolved
power-law endpoints; zero endpoints, near-flat/1/f and extreme conditioning
use independent analytic/high-precision references, with no physical floor.

B45-6 adds `cs_bsim45_invalidate_trial`: exclusive, allocation-free authorization
invalidation without accepted-history mutation. The Swift owner invokes it before
its own padded-buffer validation, so rejected Swift inputs cannot leave a stale
commit token valid. All C numerical equations and resource ownership are unchanged.
