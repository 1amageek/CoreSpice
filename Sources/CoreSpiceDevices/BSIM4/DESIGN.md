# BSIM4 Production Device

## Purpose and Scope

This component owns native Level54 exact Berkeley 4.8.3 preparation and binding.
Parent: [Devices](../DESIGN.md). It composes the verified safe kernel; it owns no
physics equations, solver or correlated noise implementation.

## Responsibilities and Boundaries

The checked preparation/binding boundary is owned by
[MOSPreparation](../MOSPreparation/DESIGN.md). BSIM4Descriptor retains registry
metadata and refuses raw bind with MOSBindingFailure.missingPreparedReceipt.
Its initializer selects polarity only; registry construction accepts no numerical
policy or noise request. Explicit MOS preparation conditions own those choices.
NativeMOSDevicePreparer admits separate resolved model/instance roles, exact
version, IC and explicit conditions/stress policy. Consuming BSIM4PreparedDevice
binding maps every original auxiliary role to fresh canonical owned nodes.
The former dictionary-based BSIM4Preparation API is removed because it bypassed
resolution identity and had no caller beyond the retired descriptor route.
BoundBSIM4
owns matrix mapping and exclusive transient history sessions; Analysis owns solve,
acceptance, cancellation and begin/defer-end lifetime. Kernel qualification limits
are immutable public metadata, independent of successful electrical execution.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Devices](../DESIGN.md) | parent | Registry and throwing stamp protocols | Native selection | No L3 fallback |
| [Safe kernel](../../CoreSpiceCompactModels/BSIM4/DESIGN.md) | depends on | BSIM4Evaluating | Exact bounded physics | Kernel evidence is not production proof |
| [MOSPreparation](../MOSPreparation/DESIGN.md) | used by | Exact prepared owner and consuming bind | Single cold setup per run | Raw descriptor binding is intentionally unsupported |
| [Analysis](../../CoreSpiceAnalysis/DESIGN.md) | used by | Session and acceptance scope | Actual CPU analyses | End on return/throw/cancel |
| [IO](../../CoreSpiceIO/DESIGN.md) | used by | Explicit caller preparation policy | Deck/CLI composition | Conditions are fixed before cold setup |

## Architecture

```text
checked exact 4.8.3 MOS + explicit conditions/capabilities/stress policy
    -> one cold kernel -> noncopyable prepared owner + topology receipt
    -> private nodes / compiled full sparsity -> consuming binding
    -> BoundBSIM4 Mutex -> DC / complex AC / BE / trapezoidal
                        -> atomic accepted-bias evaluate + commit
```

## Contracts and Invariants

- Exact 4.8.3 is selected when omitted; another literal never substitutes this
  release. Preparation without policy fails before kernel allocation. A positive
  UInt32 maximumStressIterations is the caller's work budget, not a model parameter.
- Original mult_i, mult_q and mult_fn retain independent meanings. Outer m is a
  positive finite parallel-instance multiplier applied once to electrical stamps.
  Kernel representative history remains unscaled. Invalid scaling fails before
  any partial stamp. Model and instance selector provenance is never flattened.
- Local slots 1...4 map D/G/S/B; slots 5...12 map fresh owned nodes in original
  creation order. All gate/body/series/q roles, aliases and active matrix pairs
  remain. Missing, duplicated or exposed private ownership fails before execution.
- Terminal IC anchors port voltages consistently with ground/alias constraints.
  Prime/mid gates copy gate voltage, prime drain/source copy their ports, all body
  roles copy bulk voltage; the nonphysical q-deficit coordinate starts at zero.
- DC/transient stamp the original full matrix and equivalent RHS. AC stamps the
  original frequency-dependent complex matrix. Original AC has no explicit q row;
  the adapter constrains that reserved transient coordinate to q_ac=0 with a unit
  diagonal, independently of solver gmin. No physical admittance is approximated.
- Each transient run acquires one session before history mutation. Trial and
  rejected/failed evaluations preserve accepted history. Acceptance re-evaluates
  and commits atomically under the owner lock. Concurrent acquisition fails before
  mutation; Analysis releases acquired sessions on every exit and partial failure.
- Noise follows the explicit preparation and correlated composition contract below.
  Mode1 warning and immutable maintainer limitation remain observable even when
  paramchk suppresses warnings.

## Runtime Flows

The approved [MOS preparation flow](../MOSPreparation/DESIGN.md#runtime-flows)
owns single cold setup, receipt publication and consuming binding. This component
preserves the existing Analysis-owned begin/end session and accepted-bias atomic
re-evaluate/commit sequence; cancellation/failure releases acquired sessions before
analysis exit. No new setup occurs between points of one prepared DC schedule.

## State, Ownership, and Lifecycle

| Logical state | Native / WASM / Embedded storage | Access / release |
|---|---|---|
| Mapping, policy, diagnostics, qualification | Immutable Sendable values | Construction / reads / owner lifetime |
| Session flag and composite kernel sequence | Same Mutex<State> | begin/end/stamp/commit; run-scope end |
| Original context/history | Safe evaluator's existing Mutex | Protocol calls; locked exactly-once destruction |

Lock order is bound owner then evaluator. No reverse call, external callback,
I/O or await occurs under either lock. Mapping is fixed at bind time; runtime
bias uses SIMD16 and CSR mapping uses four fixed SIMD64 integer blocks. Source
synchronization is identical on every target; only host CPU runtime is proven.

## Failure, Concurrency, and Constraints

Missing policy/model, version/parameter/admission, topology, numerical, session
and unsupported-analysis failures propagate through actual checked callers.
The approved S3 owner fixes the selected caller policy before cold setup and
compares it at consuming binding; no global configuration or physical IR parameter
carries it. Safe kernel resource ceilings remain.

## Verification and Change Impact

[CoreSpiceBSIM4IntegrationTests](../../../Tests/CoreSpiceBSIM4IntegrationTests)
owns frontend provenance, policy failures, all auxiliary sparsity, bound finite
derivatives, independent actual DC/AC/transient, IC, rejected trials/session
contention, partial-acquisition/failure/cancellation cleanup and noise refusal.
The corrected kernel charge-multiplicity contract is a prerequisite; its new
finite-derivative/sanitizer proof replaces affected historical transient evidence.
Revalidate
changed Lowering, IO, CLI and Devices consumers once after convergence. Metal,
WASM/Embedded and foundry qualification are not established by host CPU proof.

## Noise Composition

[Output-referred noise](../OutputReferredNoise/DESIGN.md) carries all physical
port/owned-node complex transfer values into the original safe noise evaluator.
BoundBSIM4 applies outer m once to the fourteen V²/Hz channels, retaining original
mult_i/mult_fn semantics and AC mult_q/NQS behavior. It consumes immutable gains
inside its existing owner lock; no solver/callback is retained or called there.

The checked owner derives noise preparation from the portable requested-analysis
capability contract before topology allocation and the single cold setup. Electrical-only and noise-capable contexts follow original
b4set semantics, including noise-only series nodes for tnoimod1. Preparation identity and
consuming binding must preserve that same choice. A later NoiseAnalysis on electrical-only
preparation fails before OP. Mode1 execution keeps its conditional warning and
immutable unqualified maintainer limitation; execution is not trust qualification.

[CoreSpiceBSIM4NoiseTests](../../../Tests/CoreSpiceBSIM4NoiseTests) owns original
mode/scaler/temperature/topology/NQS spectra and integration, complex interference,
history/concurrency, typed numerical/admission failures, cancellation and CLI.


## Approved Single-Owner Preparation

Status: designed for S3; runtime completion is recorded in workspace PROGRESS.md.
[MOSPreparation](../MOSPreparation/DESIGN.md) owns the public preparation protocol,
portable identity matching, local capacities, cancellation boundaries and binding
failure contract. This component owns its release-specific physical mapping.

The prepared value is noncopyable. Its evaluator is private and concrete, created
fresh by the factory, with no outward evaluator getter or initializer accepting
another evaluator. Consuming binding transfers that sole native reference into
the existing BoundBSIM Mutex state. Standalone CompactModels evaluator APIs are
independent and unchanged. The outer history/session lock and evaluator lock are
both retained, with the existing outer-to-inner lock order.

Model TNOM, when supplied, remains authoritative. When absent, only the derived
kernel configuration receives caller nominalTemperatureKelvin minus 273.15 as
Celsius TNOM; the original resolved model and suppliedness evidence are unchanged.
Ambient temperature and both caller condition values remain fixed by preparation
identity. Existing kernel Celsius conversion is used once.

Before publishing the prepared owner, the local budget includes the safe
evaluator's exact C allocation query and Swift retained/temporary capacity.
Failure destroys the evaluator once; consuming bind checks every required CSR
pair, topology alias and terminal IC constraint before the final nonthrowing
BindingContext claim commit. No missing active matrix entry is silently omitted.
Direct preparation tests cover failure/drop/transfer lifetime, condition/identity
drift, capacities and cancellation; existing integration/noise tests own
unchanged physical stamps and accepted-history behavior. Root composition owns
actual single-run transfer and no cold setup between DC points.
