# Independent OSDI Circuit DC Verification

## Purpose and Scope

Own the S3 same-artifact independent circuit DC reference and physical-residual
re-evaluation. Parent: [CoreSpice](../../DESIGN.md). No children. This is a native
verification tool, not a production solver, model implementation or qualification
of model physics. Input ownership is the [analytic and circuit fixture design](../../Tests/CoreSpiceOSDITests/Fixtures/DESIGN.md).

## Responsibilities and Boundaries

The C executable includes only the unchanged pinned OSDI 0.4 header and platform C
libraries. It loads the caller-selected artifacts directly, prepares separate
model/instance storage, derives setup collapse classes and assembles circuit
equations independently. It neither links COSDI/CoreSpice nor imports their
mapper, stamper, convergence or sparse solver. A Python builder compiles fixtures,
checks exact identities, translates checked JSON requests to explicit argv, and
captures immutable receipts. Model source, compiler, generated native artifact and
caller policy remain separate identities. Evaluation never invokes a compiler.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md#s3-osdi-dc-integration-contract) | parent | Same-artifact DC evidence | S3 numerical owner | Ordinary DC points do not certify all histories |
| [Fixtures](../../Tests/CoreSpiceOSDITests/Fixtures/DESIGN.md) | depends on | Exact circuit requests and analytic laws | Discriminating inputs | Tolerances freeze before execution |
| [OSDI adapter](../../Sources/CoreSpiceOSDI/DESIGN.md) | verification target | Setup projection and equation contribution | Production path under test | No implementation sharing |
| [Equation convergence](../../Sources/CoreSpiceAnalysis/EquationConvergence/DESIGN.md) | verification target | Explicit unknown/equation units | Success and failure gates | Do not use electrical units for thermal equations |
| [Point oracle](../../../swift-osdi/Tools/OSDIEvaluationVerification/DESIGN.md) | coordinates with | Header and direct ABI calling convention | Existing point evidence | S2 expected point values are not DC circuit solutions |
| [Compiler profile](../../../swift-openvaf/Tools/OpenVAFCompilerProfile/DESIGN.md) | depends on | Exact full-residuals compiler profile | All-coordinate F/G | Compiler defaults do not satisfy this profile |

## Architecture

```text
explicit compiler/profile/header + analytic VA -> generated analytic artifacts
explicit unchanged BSIM artifact + expected SHA -> admitted same artifact
                    |
checked circuit request -> direct C ABI setup -> independent collapse/incidence
                    -> raw F/G + independent R/V/I equations
                    -> dense correction Newton -> solution and residual receipt
CoreSpice returned complete solution -> same request / validate mode -> residual receipt
```

## Contracts and Invariants

### Artifact admission

The S3 BSIM artifact is the unchanged BSIM-BULK 107.2.1 full-residuals image with
SHA-256 `55b05d39103bc927251ae9ba43d7984b271016b70127a074cda9657abd4a8e38`.
The exact compiler SHA-256 is
`386a0f9b52e083c3f15f3642ef76937def3258c16e8f270fa797a853941f913c`;
the header SHA-256 is
`0f3eeb9ef3c9f0bea9b3c59f34c632555e2367f6e28722e219d8c3f1d655a16f`.
Paths are explicit caller inputs with no sibling-directory discovery or fallback.
The builder verifies the existing compiler-profile and BSIM artifact receipts and
checks their referenced bytes before use. Generated analytic VA uses that compiler
and `--full-residuals`. Header, source/include, request, builder, C executable,
compiler/profile and artifact hashes enter the captured manifest.

### Circuit and numerical boundary

Electrical external nets, positive/negative R/V/I terminals, per-instance typed
parameters, connected descriptor terminals, Kelvin ambient, previous state and
initial guesses are explicit. Positive independent current flows from positive to
negative terminal; the voltage-source branch current has the same orientation.
All raw coordinates in a generated collapse class have one circuit value. Ground
contributes no unknown. Surviving internal coordinates remain instance-private.
Every private unknown, including auxiliary, flow and thermal coordinates, is solved.
V/A, A/V and K/W are supported unit pairs; other pairs fail explicitly. Thermal
unknowns represent the model's temperature rise, not ambient temperature.

For independent raw-to-global incidence P, the oracle assembles
`Fglobal(x) = sum(P^T Fraw(Px)) + FRVI(x)` and
`Jglobal(x) = sum(P^T Graw(Px) P) + JRVI(x)`.
Newton uses the correction equation `J delta = -F`, a bounded dense partial-pivot
LU and residual-reducing backtracking. The stopping decision requires both the
unit-aware update and physical residual predicates. Nonfinite values, singularity,
stagnation, exhausted iteration/backtracking limits and native model flags produce
explicit failure. No source stepping, gmin substitution, equation pruning or model
fallback is implicit. Final accepted equations retain original full source values.
Fixed evaluation requests F/G and DC/static/operating-point flags at time zero,
with limiting off. Previous state stays unchanged throughout a solve; candidate
next state does not become accepted history during Newton or validation.

Unknown tolerances are explicit by V/A/K, equation tolerances by A/V/W, and relative
tolerance is explicit. An unknown update uses `atol(unit) + reltol*abs(x)`.
A physical residual uses strict `atol(residualUnit)` without relative inflation.
Physical-term absolute sums and a finite-precision assembly allowance are recorded
as diagnostics; neither enlarges that acceptance threshold. The scale never
comes from the production Newton RHS `J*x-F`. All fixture policies freeze in the
request before capture; failures remain failures without changing a tolerance or
dropping a coordinate. Direct analytic comparisons use the recorded policy and
floating-point operation error; ordinary BSIM comparisons do not claim interval
inclusion or foundry qualification.

### Input and output schema

`corespice.osdi.dc-inputs.v1` owns a bounded `cases` array. Each case contains:

| Field | Contract |
|---|---|
| `id` | Stable unique fixture identity |
| `devices` | `id`, library key, descriptor index, Kelvin, connected terminal count, terminal-name-to-net bindings, typed scoped parameters, explicit previous state |
| `resistors` | ID, positive net, negative net, positive finite ohms |
| `voltageSources` | ID, positive net, negative net, finite volts |
| `currentSources` | ID, positive net, negative net, finite amperes |
| `initialUnknowns` | Optional unique semantic ID to finite value assignments |
| `policy` | Explicit absolute unknown/equation tolerance maps, relative tolerance, iteration/backtracking bounds |
| `expectedOutcome` | `converged`, `singular`, or `nonconvergent` |
| `analyticUnknowns` | Optional independently derived solution values |

The builder resolves library keys only through its explicit caller-provided
artifact table. It emits an argv-based direct executable command; no shell or
production parser is involved. Solve and validate modes share the exact circuit
request. Validate requires a unique, finite candidate for every non-ground
semantic unknown, rejects extra/missing IDs, and evaluates its physical residual
without Newton or solution repair.

`corespice.osdi.dc-result.v1` retains status, iterations, all unknown IDs with unit
and residual-unit pair, solution, equation residual, physical term scale,
normalized residual, and per-device raw-node-to-semantic-ID projection. Semantic
unknown IDs are `net:<name>`, `branch:<voltage-source-id>`, and
`device:<instance-id>:node:<representative-raw-node-name>`; a private class uses its
lowest raw descriptor index as representative. The raw-node projection permits a
test to join by descriptor name even when production uses different internal IDs.
External net IDs are shared; private IDs are never shared across instances.
Failure output retains its exact stage/reason and available numerical diagnostics,
and never contains a completed solution receipt.

`corespice.osdi.dc-manifest.v1` retains complete checked requests, raw solve results,
explicit base argv for validate mode, and content/command receipts. The consuming
Swift test joins every production unknown through the fixture circuit and raw-node
projection, compares every solution coordinate/source current and invokes validate
on the complete returned vector. Comparing only terminal voltage is insufficient.

## Runtime Flows

Builder admission -> bounded cold fixture compilation -> standalone C compilation
-> bounded per-case solve -> analytic checks -> immutable manifest. Validation
executes the recorded exact circuit with a caller-supplied complete candidate and
returns residual evidence. Publication occurs only after the complete manifest is
written successfully into a fresh directory; published evidence is not rewritten.

## State, Ownership, and Lifecycle

Each C invocation owns all native models, instances, stable solve/Jacobian buffers,
previous/next state, mappings and dense solver workspace. Pointers given to the
model retain their addresses until the invocation ends. Libraries stay loaded
until all dependent storage has been released. The executable has no shared
mutable runtime state, persistent model cache or background work.

## Failure, Concurrency, and Constraints

The profile bounds device/node/state/parameter counts, argv/input/output bytes,
dense dimension, allocation byte products, Newton/backtracking operations and
subprocess time. Limits are checked before materialization; multiplication and
span checks reject overflow. The builder gives every child a timeout and terminates
its process tree on timeout/failure. Capture records argv, exit status, elapsed
time and stdout/stderr identities. Trusted native code is assumed; this is not a
malicious-pointer sandbox. Initial qualification is macOS arm64 Native CPU.

| Bound | Value |
|---|---|
| Device / raw nodes per device / global unknowns | 16 / 64 / 128 |
| R, V or I elements per family | 64 |
| States per device / parameters per descriptor | 128 / 8192 |
| Single / aggregate requested heap allocation | 64 MiB / 128 MiB |
| Input JSON / argv bytes / child output file | 1 MiB / 1 MiB / 4 MiB |
| Child wall time / CPU time | 30 seconds / 30 seconds |
| Newton iterations / backtracking attempts | Caller policy, maximum 1000 / 41 |

## Verification and Change Impact

Analytic current-driven, mixed collapse/private-node, flow and cubic fixtures
reject sign/mapping/Newton/unit errors. A no-root or bounded-iteration fixture
rejects false convergence. Same-artifact n/p forward/reverse BSIM, free drain with
resistive load, retained series nodes and free thermal balance exercise the actual
DC circuit path. All returned coordinates and source currents require independent
residual validation. Adapter tests own production comparisons; this tool owns its
analytic self-checks and command/provenance refusals. Changes to equations,
mapping, unit policy, model/compiler/header or source identities invalidate the
corresponding fixture capture before a new success claim.

### Retained initial capture

The first native capture completed in 3.228 seconds with six actually generated VA
artifacts, eight unchanged-artifact BSIM cases and seven analytic/failure cases.
Thirteen cases converged; the no-root case was singular and the one-iteration
cubic case did not converge. Nineteen analytic unknown checks, thirteen complete
solution revalidations and three malformed/wrong-candidate rejection checks passed.
The free BSIM thermal result was a 0.006743935598302726 K rise with a
3.8116482626443515e-20 W residual. These are local ordinary-point observations;
CoreSpice agreement belongs to the consuming tests and is not inferred here.

## S4 Independent Dynamic Qualification

The approved [S4 package contract](../../DESIGN.md#s4-dynamic-osdi-composition-contract)
extends this tool component with one direct-ABI analysis driver. Shared admission,
raw topology, parameter assignment and dense real solve helpers remain in this
component. The dynamic driver adds independent complex LU, direct Q/C projection,
time integration and source-index PSD transfer; no Swift numerical source is used.
S3 snapshots/executables/manifests remain immutable. Dynamic observations require a
fresh executable, source snapshots and `corespice.osdi.analysis-manifest.v1` capture.

### Evaluation and history contracts

All contexts request F/Q/G/C and OP. AC uses ANALYSIS_AC; noise uses AC|NOISE plus
CALC_NOISE; transient uses TRAN; explicit initialization uses TRAN|IC|STATIC. The
absolute time is an explicit finite nonnegative input. Native previous state is
copied from accepted state for every evaluation and untouched candidate slots are
initialized from it. Generated state indices are installed explicitly. Candidate
state/Q/F becomes accepted only after a converged step satisfies its original
physical equation and current-trial bound-step limit. Rejected trials retain the
same Q/F/native accepted state. Initial UIC values are preserved without inventing
a DC solve. Native state and external charge history remain separate owners.

AC independently assembles `Y=P^T(G+j*omega*C)P+YRVI` and checks complete complex
candidates against `Y*z-b`. Transient BE checks `F+(Q-Qprev)/h`; TR checks
`F+2*(Q-Qprev)/h+Fprev`. This uses evaluated Q, never C*x. Accepted records carry
absolute time, h and actual BE/TR method. Time-discretization accuracy is assessed
separately on h/h2/h4 grids with declared comparison outputs and fixed tolerances.

Noise evaluates fresh generated `load_noise` PSD at each positive frequency after
the same noise-context evaluation. The signed exported value already includes factor².
For fixed-bias small-signal analysis, each finite native value becomes
`density = abs(rawSignedDensity)` before the independent source transfer solve.
Both quantities are retained per source. This matches the consumer contract for
signed Verilog-A noise powers without changing source physics or endpoint order.
NaN and either infinity fail explicitly before transfer or output publication.
Each descriptor source index retains its raw endpoint pair and A/V/W equation
unit; collapsed endpoints cancel and ground has no row. Transfer solves use all
internal/thermal/flow coordinates. Output PSD sums independent source-index
contributions; correlated model effects remain in the generated auxiliary G/C
network. External resistor thermal PSD is explicitly 4*kB*T*g with the same exact
Kelvin and Boltzmann constant as the declared circuit. Input voltage/current
referral preserves V²/Hz/A²/Hz respectively. Nonfinite raw noise, unsupported
nature/type, zero/nonfinite input transfer and integral overflow fail explicitly.

### Dynamic manifest boundary

`corespice.osdi.analysis-manifest.v1` retains the existing library records and
`cases: [{id, kind, family?, input, reference, validationBaseCommand}]`.
`input.circuit` is the unchanged S3 circuit request; `input.analysis` owns:

| Kind | Input |
|---|---|
| AC | `frequenciesHz`, `stimulus: {sourceID, real, imag}` |
| Noise | `frequenciesHz`, `output: {positiveUnknownID, negativeUnknownID?}`, `inputSourceID`, `resistorTemperatureKelvin` |
| Transient | `initialization`, `uicInitialUnknowns`, `stimulus: {sourceID, points: [{timeSeconds, value}]}`, `steps: [{timeSeconds, timeStepSeconds, method}]` |

References retain actual OP, every semantic unknown with units, full complex
frequency solutions, per-source index/PSD/transfer/output contribution, input gain,
integrated output noise and accepted transient time/h/method/history facts.
Validation consumes a complete external candidate at the recorded circuit/context;
it never repairs a failed candidate by solving it. Production adaptive transient
audit supplies its actual accepted methods/times for exact physical replay.

### Matrix and resource evidence

The real matrix contains three circuits per exact family: n-loaded, p-reverse and
series/thermal/correlated-noise, each with three AC/noise frequencies and short
nonzero transient stimulus. Analytic generated controls own complex RC, nonlinear
Q, non-ground UIC, flow/thermal rows, mode/time/IC, white/flicker noise and retained
state. A separately labeled two-slot ABI fixture owns native transport/failure
controls. Model physics and universal hidden-state support are not inferred.

Every child retains the existing 30-second wall/CPU and output bounds. Capture
checks free disk above 2 GiB before materialization and each child and uses at most
two concurrent jobs. Frequency/step/channel/unknown counts, history snapshots,
complex buffers and dense work are pre-admitted. Fresh captures record exact
header/compiler/profile/image/source/argv and preserve prior receipts unchanged.

The final S4 capture and independent candidate/accuracy checks are recorded by the
[family capture owner](../OSDIModelQualification/DESIGN.md#retained-s4-dynamic-evidence).
The candidate validator rejects a manufactured UIC operating point and preserves
the supplied non-ground initial vector without testing it as a DC equilibrium.
Normal initialization requires an actual complete operating-point candidate.

### Candidate capacity profile

The Native qualification profile admits at most 1000 accepted steps. A separately
compiled verifier matches that explicit bound and admits one eight-MiB flattened
candidate file; the historical 256-step executable remains immutable. Only these
two admission constants change. The 1001-by-128 real/imaginary/presence arrays and
1000 step records have static storage; increasing capacity adds no stack-sized
history allocation. Unknown, argv-count/byte, wall/CPU and output limits remain
independent admission conditions. Layout and compiler stack-usage receipts record
actual storage, separately from the chosen output-disk reserve policy.

Derived manifests retain `oracle` as the historical numerical-reference authority
and bind the new source/header/compiler/executable as `validationOracle`. A
`validationProfile` selects the supported eight-MiB candidate bound and 64-MiB
output reserve. Unchanged equations, iteration/update criteria and per-unit
residual tolerances are verified by an exact two-constant source delta and
targeted old-domain numerical agreement. A 1000-step positive replay, 1001-step
rejection and corrupted large-candidate rejection establish the changed boundary.

## S4D Independent Compensated Replay Design

The [Precision child](Precision/DESIGN.md) owns the independent higher-precision
program evaluator, complete paired-trajectory replay and source-derived controls.

### Fixed-bias signed-noise reference migration

The prior fifty-case snapshot classified four finite signed reverse-polarity noise
powers as expected failures. That classification belongs to the prior consumer
contract and does not establish model failure. A fresh independent executable
recaptures only those exact four case IDs under the fixed-bias absolute-value
contract. Inputs, frequency/settings, all model artifacts and the other forty-six
references remain unchanged. The derived manifest binds its immutable parent,
source snapshots, new executable and bounded actual capture commands; raw signed
values stay visible alongside nonnegative density and transfer contribution.
Validation commands use the fresh executable for the same complete-candidate
checks. This migration does not repeat unrelated DC or trajectory captures.
