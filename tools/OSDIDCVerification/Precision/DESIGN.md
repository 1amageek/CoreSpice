# Independent Precision Replay

## Purpose and Scope

Test-only independent precision point evaluation and complete accepted-trajectory
replay. Parent: [independent verification tool](../DESIGN.md). No children.
Implementation is authorized for S4D.10. No production model or solver ownership.

## Responsibilities and Boundaries

Own a standalone MPFR-directed parser/evaluator and original-equation replay.
Share published schema declarations only; no production worker linkage/code reuse.
The parent tool retains ordinary C ABI DC/AC/noise and historical references.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Parent](../DESIGN.md) | parent | Independent verification identity and limits | Ordinary numerical authority | Preserve old receipts |
| [Model precision](../../../../swift-osdi/Sources/OSDIContracts/PrecisionEvaluation/DESIGN.md) | depends on | Complete F/DeltaQ contract | Model-owned semantics | Stateless profile only |
| [Compiler program](../../../../swift-osdi/Sources/COSDI/CompilerPrecision/DESIGN.md) | depends on | Pointer-free program/setup schema | No arithmetic implementation shared | Exact schema/profile bound |
| [Qualification](../../OSDIModelQualification/DESIGN.md) | used by | Immutable captures | Actual API/CLI evidence | Source-level adversaries required |

## Architecture

```text
exact program/setup + independent paired endpoints
 -> standalone MPFR-directed stages/CFG/phi
 -> enclosed raw F and DeltaQ
 -> complete circuit mapping/accepted history -> strict physical gates
```

## Contracts and Invariants


This component owns the test-only precision reference. The lower models-5/a85f and
compound-3 programs authorize the first independent point implementation. Ordinary direct-ABI
DC/AC/noise and the historical four-family references retain their current scope.
No model equations enter the production simulator through this reference tool.

### Responsibility and independent authority

The reference is a separate standalone MPFR-directed evaluator with its own
bounded program parser, register/CFG/phi execution, setup and endpoint evaluation.
It shares only the published
[compiler program schema](../../../../swift-osdi/Sources/COSDI/include/OSDICompilerPrecision.h)
and the model-owned
[precision mathematical contract](../../../../swift-osdi/Sources/OSDIContracts/PrecisionEvaluation/DESIGN.md).
It does not link COSDIPrecision, call the production worker, reuse its interpreter
or use rounded native Q as an acceptance input. Installed public MPFR 4.2.2 and
GMP 6.3.0 headers/libraries provide the primitive arithmetic; their exact files,
compiler, source and executable identities must be captured before use. Sharing
MPFR is not independent qualification of MPFR itself.

```text
official source + exact compiler/image -> immutable exported precision program
original typed inputs + independent ABI setup -> scoped facts/raw topology
saved complete high/low coordinates + original contexts + actual h pair/method
  -> independent three-stage directed evaluation at both endpoints
  -> raw F and Q(candidate)-Q(reference)
  -> independent mapping/RVI assembly + accepted Iq recurrence
  -> unchanged per-row absolute residual gates
source-derived controls + ordinary ABI points -> separate emitter/axis checks
```

The native export is read directly from the admitted image's
`OSDI_PRECISION_V1_COUNT`/`OSDI_PRECISION_V1` records. Every pointer/length/index is
validated before copying the pointer-free little-endian program. The semantic
profile, program bytes, descriptor, primitive literal bits and all historical
source/compiler/image receipts remain exact authorities. No new public debug
format is necessary. The program is computational authority for checking the
worker and integration; it is not independent proof that the compiler faithfully
translated every official model expression.

Setup facts are independently reconstructed from the original typed scoped/given
assignments and simulation facts, ordinary descriptor parameter metadata and the
existing independent C preparation/topology path. Parameter-table model/instance
entries, aliases and given flags retain their distinct meanings. Native resolved
defaults/cache values are never exact setup leaves. All emitted collapse roots
must reproduce the independently prepared equivalence classes and raw-to-global
mapping; matching counts alone is insufficient.

### Mathematical and history contract

Each coordinate and time is the exact real sum of its finite normalized binary64
components, imported separately. Primitive constants and supplied real inputs
use their exact decoded binary64 bits. Model setup, instance setup and evaluation
execute afresh for each endpoint with that endpoint's original mode/time. Initial
Q retains TRAN|IC|STATIC context; later accepted Q retains its original TRAN
context. UIC initial coordinates are retained without imposing a manufactured DC
equilibrium. Comparison/branch/cast results must be proved by enclosures, never chosen
from an interval midpoint. Unsupported operations and state fail immediately. Arithmetic domain or
indeterminate values retain an explicit invalid status through arithmetic and
selected phi/SELECT values. An invalid observable root, collapse/step bound or
required control predicate fails explicitly; unselected invalid values do not
replace a valid selected value. Missing definitions, unknown opcodes, model status
and resource exhaustion remain immediate failures. An invalid branch predicate may skip only a proved finite acyclic pure region
whose every path reaches a common join. The independent implementation computes
postdominators on a bounded acyclic reachable graph; it never guesses a branch.
Every skipped definition and join phi is poisoned. Terminal model-status effects,
loops, missing join or malformed structure reject immediately; a later definite
phi/SELECT may discard poisoned values. This is the root-selected inactive-value
contract; the original eager-domain pilot remains preserved.

The interpreter uses directed MPFR lower/upper values, with a declared bounded
precision ladder higher than the production request. Precision refinement
reexecutes the complete endpoint computations. A scalar high-precision agreement
alone is insufficient: the reference must enclose input formation, setup, every
operation, endpoint subtraction and circuit accumulation. It evaluates the full
nonlinear F/Q expressions, never F(high)+G*low or C*DeltaX. G/C are not final
acceptance authorities. Version-one stateful precision is rejected; ordinary
stateful tests remain on their existing independent lane.

The saved scheduler endpoint is its binary64 time with zero low. Verify the saved
interval high+low equals the exact difference of candidate and accepted endpoint
times; do not reconstruct an endpoint from rounded time-h. The reference evaluates
both Q endpoints before subtraction and propagates accepted reactive current as:

| Accepted method | Independently reconstructed reactive current |
|---|---|
| BE | `Iq = DeltaQ / h` |
| TR | `Iq = 2*DeltaQ / h - previousAcceptedIq` |

The initialization seed is zero, and the first positive accepted method is BE as
guaranteed by Analysis. Do not replace accepted Iq with -F(previous), because the
previous accepted physical residual need not be exact zero. Every device, RVI
element, internal/flow/thermal coordinate and branch current participates in the
same independent semantic mapping. For every positive accepted step's assembled row, prove
`max(abs(lower), abs(upper)) <= originalEquationAbsoluteTolerance`, using its
unchanged A/V/W equation unit and exact tolerance value. Boundary-spanning
enclosures are failures. No relative residual inflation, dropped low component,
native-Q substitution or tolerance change is admitted.

### Source-level adversaries and proof limits

Two source-derived controls complement SSA replay and ordinary native-C point
checks. They catch target emitter/encoding mistakes that replaying a shared bad
program would miss; they do not constitute formal proof of BSIM physics.

| Witness | Independent authority and detected counterexample |
|---|---|
| Existing binary-exact nonlinear fixture | Its source F/Q formula, evaluated separately through MPFR, distinguishes full F(high+low) from a tangent and nonlinear charge from C*DeltaX. Compound setup expressions remain operations. |
| Official IMG thermal Q | `bsimimg_body.include` geometry lines 811-836, setup lines 1265-1267 and contributions lines 2623-2626 derive `cth=CTH0*(WTH0+Weff)*NF`, `Qthermal=cth*temperatureRise`. Geometry/default inputs are evaluated from these source expressions, never imported rounded cth. Sub-ulp endpoint changes must produce the corresponding nonzero DeltaQ even when native rounded Q agrees. |
| Ordinary direct ABI points | Existing frozen native raw F/Q/G/C and topology checks identify root-axis, polarity, setup and mapping errors in the admitted compiler profile. Their ordinary numerical comparison policy is distinct from the strict precision circuit gate. |

Deliberate opcode/root-axis mutation, missing/zeroed saved lows, tangent-only F,
rounded-Q subtraction and incorrect h/context/history must be rejected by the
appropriate source/control or physical witness. Exact image/program/setup/profile
mismatches fail admission before numeric execution. Qualification concerns these
recorded models, fixtures and compiler profile; it is not a universal source
equivalence or all-history guarantee.

### Resource admission and remaining composition seam

The parent qualification profile owns maximum program bytes/sections/registers,
executed instructions/branches, precision bits/ladder, points/unknowns, input/output
bytes and child count. Checked products bound owned parser/register/result
storage before allocation. MPFR internal allocation and complete process memory
must be accounted separately; fixed register precision alone is not a zero-heap
or complete RSS proof. Existing child wall/CPU/output deadlines remain mandatory,
and timeout/work/precision/resource exhaustion publishes no successful receipt.
One cold two-endpoint pilot per admitted program determines instruction counts,
storage and measured cost before the bounded full-trajectory run; no cost claim
is inferred from ordinary C or arithmetic-only tests. C compilation is limited to
this standalone test tool, with at most two jobs and no shared Swift build.

The remaining composition seam is the Native/artifact candidate projection of
the already-owned paired traces: numerical profile and program/preparation
identities, complete semantic coordinates/units, both component bit patterns,
original endpoint contexts, actual time/h/previous-h components and accepted BE/TR
methods. Analysis already owns these values and guarantees first BE. The existing
ordinary candidate DTO lacks precision fields. Native/artifact must freeze their
durable projection before replay implementation; the oracle adapts to that schema
rather than introducing a second public result/debug format. Save/reload must
preserve the component bits, and a precision record missing them fails explicitly.


## State, Ownership, and Lifecycle

One trusted child owns immutable file bytes, typed registers, MPFR values and
scratch. Each endpoint resets all definitions and independently executes three
stages. No values from the production worker or across endpoints supply results.
Owned allocations are released on normal/error exit; parent timeout kills/reaps
the process. Program/setup/vector inputs and result sizes are independently capped.

## Failure, Concurrency, and Constraints

The private point CLI uses explicit program/setup/paired-vector files, precision
and work cap. `driver.py build --output <fresh-directory>` freezes the C/header,
Python drivers, compiler and MPFR/GMP identities. `driver.py point` consumes a
private JSON request with program/setup paths and their required SHA-256 values,
four vectors and candidate/reference contexts; it preserves the published program
and setup layouts. The 56-byte little-endian `OSDIREF1` point header contains
version, active count, two mode values and four time components, followed by the
four contiguous binary64 vectors. It is a tool-private transport, not a product
artifact schema. The driver publishes exact execution/input/output receipts only
in fresh directories, with 30-second wall/CPU, 4-MiB per-output and 64-MiB free
output-reserve limits. Exact dyadic interval endpoints own comparison; outward
decimal strings are display data and cannot widen an exact zero-radius witness.
`verify.py` authors independent layout/control fixtures and source-derived rational
compound/IMG checks; these schema fixtures are not compiler model images.
Typed stderr failures and nonzero exit publish no successful result. A 64-MiB
program ceiling, 200000-register ceiling, 128 active-coordinate ceiling, fixed
512-bit default (128...4096 admitted) and explicit operation/CFG budget bound the
initial qualification profile. These are caller operating caps, not model physics.
MPFR/GMP internal memory and measured process footprint remain separate evidence.

## Verification and Change Impact

Cold two-endpoint pilot precedes complete trajectories. Current controls retain
explicit positives for inactive SELECT/pure reconvergence and negatives for live
invalid roots/join phis, model-status effects, loops, absent join, unknown opcode,
wrong root axis and work exhaustion. The first normalized four-family comparison
checks exact source-level F/DeltaQ enclosures against worker centers plus radii;
it qualifies point behavior, not a circuit trajectory.

 Source compound/thermal
controls, deliberate wrong opcode/root/low/tangent inputs and exact ordinary image
comparisons own correctness. The parent task owns API/CLI save/reload integration.
Changes to schema, image/program, setup facts, arithmetic or history require a new
immutable capture and the affected proof, without mutating historical evidence.

### Streaming trajectory composition

The trajectory layer accumulates exact rational interval arithmetic around the
independently enclosed model F/DeltaQ values. Native source capture and effective
analysis settings, complete paired traces, exact accepted-step audit and actual
row-equation gates are mandatory inputs. Their final durable field names are
owned by the CLI schema. External R/C/L/V/I equations come from that exact captured
circuit; the verification manifest must match its source/configuration identity.
No private native element storage is inspected or inferred.

The replay projects complete global high/low coordinates to each independently
prepared active model order, evaluates both original contexts, maps every raw row
back to its global equation and sums all model and external contributions. The
per-row accepted reactive-current interval uses actual h and BE/TR; the initial
seed is zero and the first accepted method must be BE. The exact rational h-pair
must equal the difference between saved scheduler endpoints. Every positive step
is checked against its actual unchanged row gate. A missing source, map, component
bit array, context, policy or precision preparation snapshot is a typed refusal.
Per-step raw interval output is temporary until accumulated; final proof binds the
complete original trace/input/program/setup/tool bytes and retains residual
summaries. Failed steps retain their full diagnostic inputs/output. No unrelated
fixed-grid reference is used to accept an adaptive trajectory.

### C3.6 paired-artifact decoder and caller

`artifact.py` independently decodes the frozen outer-version4 / execution-version2 /
precision-version1 wire. `replay_artifact.py` composes it with the frozen standalone
point executable and pure circuit assembly. It shares no production decoder or
worker code. The CLI [precision composition](../../../Sources/CoreSpiceCLI/DESIGN.md#s4-precision-transient-cli-composition)
owns the public fields; source/scalar identity checks do not authorize execution
of stored production worker pointers. The caller executes only the independently
qualified C binary selected by an exact immutable build receipt.

The caller's explicit verification profile bounds JSON at 64 MiB, nesting at 64,
scalars/objects at two million, source bytes at eight MiB, compiled rows at 128,
accepted steps at 1000, model count at sixteen and each child output at four MiB.
Canonical base64 length is admitted before decoding and re-encoding must match.
CircuiteFoundation ArtifactID v1 framing is parsed independently (SHA-256 only).
Wire schema versions require exact integers; JSON booleans are rejected.
Completed ordinary OP model records retain schema 1 / nativeOSDI.op.v1;
transient records use schema 2 / nativeOSDI.analysis.v2, as defined by the CLI.
Immutable program header raw count and node-table indices, names and flow flags
must match the saved topology before a point child starts. Dynamic collapse maps
remain setup facts; node units/natures retain their separately published authority.
All component bits, exact normalized sums, complete raw/active/global maps,
original scoped setup facts, actual equation policy, initialization context,
accepted h/previous-h and captured source equations must agree before replay.
Unknown source grammar or unsupported elements refuse rather than being ignored.
The independent qualification profile supports the recorded flat R/C/L/V/I/PWL
and OSDI circuits, including the explicit transient quota options emitted by
the shared qualification fixture; it does not become a general SPICE frontend.

The source input and configuration identities are checked against the outer
record and the explicit qualification input. Source scalar parameters and PWL
knots are compared to the independently supplied manifest circuit when present;
original source bytes remain primary for assembly. Cold setup given facts and
Kelvin are checked against original model records, not resolved parameter caches.
The current public preparer supplies an empty simulation-parameter list; every
saved simulation fact must therefore be non-given with zero bits. A supplied
simulation override is outside this replay profile and refuses.
The public algorithm identity fixes initialization Q context TRAN|IC|STATIC and
subsequent TRAN contexts at saved binary64 endpoints with zero low. First BE and
exact h-pair differences are required. Audit previous-h denotes available
integration history: the first BE has no previous fields, TR requires a complete
previous pair, and a later BE may have all previous fields absent after a history
reset. Every supplied pair equals the preceding accepted interval exactly. The
cold record does not encode a reset cause and this check does not invent one;
the actual prior interval remains available in its own accepted-step record.
Previous accepted Iq starts at zero and
changes only after a completely verified step. All rows use the saved actual
absolute equation gate, with no relative residual allowance.

`verify_admission.py` owns the finding-specific immutable-node and exact-version
counterexamples, including self-consistently recomputed v6 identities and a
zero-point-call tripwire.
Corruption controls own canonical bytes/hash, coordinate low/bits, row map, gate,
settings/context and accepted-history refusals. Synthetic artifacts test decoding
and caller behavior only; they do not prove a production trajectory. C10 actual
saved/reloaded evidence is recorded separately from these controls. Temporary
per-pair oracle outputs are consumed and hashed before deletion; a failing pair
retains diagnostic inputs/output, and no partial replay publishes success.

The Native-owned configuration witness adds mandatory `legacyBaseDigest` and
`solverIdentity`. `binding.py` independently streams the published Native v6
canonical typed facts and final two-digest framing, then compares the result with
both stored outer and precision configuration identities. Authority is
[Native verification](../../../Sources/CoreSpice/NativeExecution/NativePrecisionConfigurationVerification.swift)
and [length framing](../../../Sources/CoreSpiceIO/SimulationPreparation/SPICEPreparationEncoding.swift).
It preserves the opaque legacy-base commitment, recomputes every typed replay
fact from decoded fields, including ordered compiled row number/kind/name/unit,
and normalizes signed zero only in canonical number
framing. It does not accept a saved facts digest or hash the JSON as a substitute.
This is internal record consistency, not a signature or external authentication;
an expected complete artifact digest remains a separate caller trust boundary.

The replay admits two exact algorithm/solver pairs under the unchanged facts-v1
and final-binding-v6 framing: current `precision.v3` with
`CoreSpice.SparseLU.SwiftCSC.v2`, and historical `precision.v3` with
`CoreSpice.SparseLU.Accelerate.v1`. Here `precision.v3` abbreviates the complete
`CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3` identifier. The current
Native verifier owns the former; the latter preserves the independently qualified
historical artifacts. The actual recorded solver bytes always enter the facts
commitment, so switching even between these supported pairs without recomputing
the exact configuration must fail. Unknown algorithm/solver versions refuse;
`precision.v2` was not admitted and receives no implicit upgrade. Model, source,
setup, row, gate, settings and both configuration identity checks are unchanged.
`verify_binding.py` checks the actual saved current binding before any point call,
plus explicit historical consistency and forged-version/commitment refusals. This
is binding admission evidence, not a numerical trajectory replay.

The caller bounds accepted-Iq storage by outward rounding its interval endpoints
to 512 significant binary digits after each fully accepted step. Exact rational
assembly and the original gate run before that update. This preserves enclosure
of the same reactive history; it does not substitute -F or change equations. It
prevents odd-denominator products from growing across a 1000-step variable-h TR
history. Passed steps retain the maximum normalized residual as an outward dyadic
summary and a complete input/output digest transcript; full row bounds are retained
for failures. Final receipts are bounded at eight MiB, with a 128-MiB output
reserve covering decoded cold snapshots, one pair's logs and receipt/snapshots.
The complete saved artifact remains bound and replayable; no output trace is
replaced by these summaries.


### C10 actual saved/reloaded qualification

The immutable local receipt
`.verification/osdi-s4/independent-full-trajectories-2/receipt.json`
(SHA-256 `8e20c87c0fccc45c5629a8aa5755bedbb904cddbf1cdd793cad13f4f73e7e2f6`)
binds all twelve original four-family CLI cases and all 24 saved/reloaded
artifacts. Both records of every pair passed independent admission; their full
model/execution/configuration semantics and paired traces matched exactly.
Each unique trace was replayed once, totaling 3400 accepted steps and 3400
independent 512-bit point evaluations. Every original row gate passed; the largest
normalized residual enclosure upper bound was approximately `1.11692e-6`, below
one. Native twelve-case execution evidence remains a separately bound matrix
prerequisite; these independent numerical results qualify the saved CLI traces.
The existing actual compound four-step BE/TR and context 198-step batch/prepared
proofs are referenced by the aggregate, without new point captures.

This receipt describes these exact artifacts, histories, tools and model images.
It does not certify unexecuted inputs or arbitrary histories. The first matrix
preflight retained a typed admission refusal because the checker had incorrectly
required transient model-record version 2 for ordinary OP records; the corrected
phase-specific version contract above is covered by focused zero-point-call
controls. No equation tolerance, model source or independent point binary changed.
