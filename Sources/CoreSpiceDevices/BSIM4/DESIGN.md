# BSIM4 Production Device

## Purpose and Scope

This component owns native Level54 exact Berkeley 4.8.3 preparation and binding.
Parent: [Devices](../DESIGN.md). It composes the verified safe kernel; it owns no
physics equations, solver or correlated noise implementation.

## Responsibilities and Boundaries

Preparation retains separate model and instance scopes, exact version and IC.
A caller-supplied preparation policy bounds original stress work. The descriptor
maps every original auxiliary role to fresh canonical owned nodes. BoundBSIM4
owns matrix mapping and exclusive transient history sessions; Analysis owns solve,
acceptance, cancellation and begin/defer-end lifetime. Kernel qualification limits
are immutable public metadata, independent of successful electrical execution.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Devices](../DESIGN.md) | parent | Registry and throwing stamp protocols | Native selection | No L3 fallback |
| [Safe kernel](../../CoreSpiceCompactModels/BSIM4/DESIGN.md) | depends on | BSIM4Evaluating | Exact bounded physics | Kernel evidence is not production proof |
| [Lowering](../../CoreSpiceLowering/DESIGN.md) | used by | Preparation and topology | Preserve provenance | Explicit policy required |
| [Analysis](../../CoreSpiceAnalysis/DESIGN.md) | used by | Session and acceptance scope | Actual CPU analyses | End on return/throw/cancel |
| [IO](../../CoreSpiceIO/DESIGN.md) | used by | One resolved preparation policy | Deck/CLI composition | Same policy reaches all rebinds |

## Architecture

```text
exact model + separate instance + explicit policy
    -> cold kernel -> required owned nodes -> compiled full sparsity
    -> descriptor -> BoundBSIM4 Mutex -> DC / complex AC / BE / trapezoidal
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
- Noise admission is explicitly unsupported until independent correlated-noise
  composition is implemented. It fails before OP/spectrum; absence of NoisyDevice
  must not silently yield successful zero noise. Mode1 warning and immutable
  maintainer limitation remain observable even when paramchk suppresses warnings.

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
Cold/rebind use the same selected caller policy; no global configuration or
physical IR contamination carries it. Safe kernel resource ceilings remain.

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
