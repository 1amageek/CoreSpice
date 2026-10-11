# CoreSpice BSIM4 4.5 Native Kernel

## Purpose and Scope

Status: B45-2 preparation and B45-3 static I/Q/Jacobians are implemented in
independent SwiftPM C target `CoreSpiceBSIM45`. AC/transient/noise and safe-owner
public execution adoption remain proposed and unavailable.
Parent: [CoreSpice](../../DESIGN.md). Child: [Kernel](Kernel/DESIGN.md).
It exposes an independently buildable exact-release preparation/static C boundary. It owns no
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
 -> complex AC | transient trial/accept | noise spectrum (future B45-4/B45-5)
 -> finite checked output publication
 -> cs_bsim45_destroy
```

The public C header belongs in `include/`; production C implementation belongs
in `Kernel/`. Selected original source files are compiled directly by this target.
No external SPICE engine is needed for build, link or runtime.

## Contracts and Invariants

Preparation and static APIs are implemented; general analysis/history/noise
operations below are future design only and have no public declarations. Release and adaptation identities are immutable
and queryable independently of a successful numerical run.

| ABI operation | Guarantee / failure boundary |
|---|---|
| `cs_bsim45_owner_size` | Exact same-build `sizeof` requested by create; no allocation, no allocator-overhead claim |
| `cs_bsim45_create` | One zeroed exclusive owner or allocation failure; exact 4.5.0 plus explicit schema/adaptation IDs |
| `cs_bsim45_set_model`, `cs_bsim45_set_instance` | Separate generated parameter ID/kind admission; supplied bits preserved; finite/range checks precede C casts |
| `cs_bsim45_prepare` | Single setup; caller-selected noise intent and work budget; publishes topology only on complete success |
| `cs_bsim45_evaluate_static` | Physical static I/Q and full analytic Jacobians; selected-branch derivative at VDS=0; atomic finite output |
| Future `cs_bsim45_evaluate` | Exact local bias, full residual/RHS/current/charge/Jacobians; explicit DC/AC/BE/TR method and conditions |
| Future `cs_bsim45_initialize_history`, `cs_bsim45_commit` | Exclusive accepted/older history; generation-bound successful trial token commits once |
| Future `cs_bsim45_noise_spectrum` | Full local complex transfer gains borrowed for call; release-specific PSD channels |
| `cs_bsim45_destroy` | Exactly-once release, including any partial preparation state |

ABI statuses distinguish invalid release/schema/parameter/conditions, unsupported
analysis, allocation/work/diagnostic capacity, nonfinite evaluation, invalid
history and cancellation admission. No partial output is authoritative on failure.
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
Unsupported requested capabilities fail before owner publication.

Future transient trials preserve accepted and older state. Rejection/any subsequent
evaluation invalidates the old trial token. Acceptance verifies owner generation
and commits once. DC/AC/noise cannot mutate accepted history. The upper bound owner
keeps accepted-bias evaluation and commit within one lock sequence.

## State, Ownership, and Lifecycle

```text
allocated -> admitting -> preparing -> prepared
                              future: prepared -> trial -> accepted
    |            |           |           |         |
    +------------+-----------+-----------+---------+-> destroyed
                              failure: never reuse partial preparation
```

One preparation allocation contains model, instance, one geometry knot, topology,
matrix, reserved state arrays and bounded diagnostics. Trial metadata remains a
future numerical-unit responsibility. Redirect original geometry
allocation to that owner; all original pointers borrow owned storage. No retained
caller pointers, mutable process-global state, filesystem logs or callbacks.
The ABI is exclusive rather than internally locking; the safe owner supplies the
same Mutex contract on every target. Destroy cannot race any context operation.

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
Future tests own AC/NQS, BE/TR history/token behavior,
noise and ASan/UBSan lifecycle/failure paths. Each implementation unit builds and
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
inspection and destroy; B45-3 adds the static operation specified below. Future numerical operations above remain
design proposals and are not declared in the C header. A failed setter or prepare
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
