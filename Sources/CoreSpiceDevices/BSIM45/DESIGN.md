# BSIM4 4.5 Production Preparation and Binding

## Purpose and Scope

B45-6 implementation contract: activate only with the scoped runtime evidence below.
Parent: [Devices](../DESIGN.md). No children. This component owns the exact 4.5
prepared owner, topology mapping and bound stamping on the existing solver path.
It owns no model search, expression evaluation or physical equations.

## Responsibilities and Boundaries

Reuse the existing [MOSPreparation](../MOSPreparation/DESIGN.md) public protocol,
identity, conditions, resource and failure contracts. Add a concrete noncopyable
`BSIM45PreparedDevice` and `.bsim45` native-owner case, rather than changing the
4.8.3 evaluator's version string. `BoundBSIM45` maps full local topology to existing
stamper protocols and owns the composite transient-session lock.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Devices](../DESIGN.md) | parent | BoundDevice and stamp protocols | Native provider registration | Correct resolution is not execution capability |
| [MOSPreparation](../MOSPreparation/DESIGN.md) | depends on | Exact receipt and consuming bind | Single cold setup | Conditions mismatch fails before executable publication |
| [Safe evaluator](../../CoreSpiceCompactModels/BSIM45/DESIGN.md) | depends on | Exact real 4.5 evaluator | Owns C lifetime and synchronization | Never expose owner alias from prepared device |
| [Analysis](../../CoreSpiceAnalysis/DESIGN.md) | used by | DC/AC/transient/session/noise protocols | Existing numerical algorithms | Run lifetime owns cleanup and acceptance |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | Prepared owner collection and actual topology | Compile then consume owners | Aggregate resources count actual topology once |
| [Schema](../../CoreSpiceMOSContracts/Schema/DESIGN.md) | depends on | Exact 4.5 input semantics | Numeric parameter projection | Raw declaration version remains inspectable |

## Architecture

```text
ResolvedMOSInstance(4.5.0) + explicit preparation conditions
 -> native provider capability check -> typed original-ID projection
 -> one BSIM45PreparedDevice + immutable receipt
 -> actual auxiliary nodes and sparse compile
 -> consuming NativePreparedMOSDevice.bsim45.bind
 -> BoundBSIM45 -> existing DC / AC / transient / noise Analysis
```

## Contracts and Invariants

The native provider, not the portable release enum, owns execution
capability. Canonical 4.5.0 selects only this implementation. Other release IDs,
including 4.62, fail explicitly. Capability checks include requested analysis and
supported supplied features, not merely a release-wide Boolean. During staged
implementation, unsupported capabilities are typed failures; reachable partial
branches need the required incomplete-implementation marker and cannot issue
completed execution evidence.

Preparation identity fixes resolution, release/schema/adaptation/implementation,
ambient/nominal conditions, analysis capabilities and policy. Existing receipt
implementation identity can encode the release adaptation digest; no duplicate
global execution registry or new resolution wrapper is needed. One run gets one
prepared owner per MOS; consuming bind moves it into bound state. A rerun prepares
again from immutable resolution. A bias/sweep point never prepares again.

Convert interned resolved symbols to canonical native IDs once under bounded
preparation work. This is parameter admission, not model-name search. Preserve
model/instance roles, supplied bits and physical defaults. Outer M multiplies
electrical stamps/noise once; NF participates in original geometry. No `mult_i`,
`mult_q` or `mult_fn` is accepted as a 4.5 original parameter. No dictionary merge
can replace a model version, selector or coefficient with an instance value.

The original full topology determines auxiliary-node admission, matrix capacity,
compile sparsity and binding. Ports/roles/aliases, IC constraints and charge-node
DC/AC constraint must be checked against the exact prepared owner. A mismatch,
resource overflow or cancellation publishes neither a partial circuit nor evidence.

## State, Ownership, and Lifecycle

| Logical state | Native / ordinary WASM / Embedded source contract | Owner / release |
|---|---|---|
| Pending executable evaluator | Noncopyable prepared value | Native execution transfers it via UniqueArray and consuming bind |
| Mapping, receipt and qualification metadata | Immutable Sendable values | Bound instance lifetime |
| Transient-session flag and evaluate/commit sequence | Same `Mutex<State>` | Bound begin/end/stamp/commit; analysis defer ends session |
| Native physical state | Safe evaluator's same Mutex owner | Exactly-once evaluator release |

Lock order is bound state then evaluator. No reverse calls, await, I/O or external
callbacks. Accepted-bias re-evaluation and commit remain atomic under the bound
lock, because an intervening evaluation invalidates tokens. Re-evaluation here is
numerical trial evaluation, not repeated expression resolution or cold setup.

## Failure, Concurrency, and Constraints

Native creation/setup failure remains destructible. Failed compilation/binding
releases all pending owners and topology without advertising a successful run.
Analysis acquisition failure/cancellation releases acquired sessions. Resources
use the actual same-build native owner size, Swift retained capacity and prepared
matrix topology; no fixture-specific raised ceiling or maximum-topology guess.
Nonfatal original diagnostics retain release-specific provenance and effective
value. Foundry accuracy and later-release maintainer warnings are not invented.

## Verification and Change Impact

`CoreSpiceBSIM45IntegrationTests` must execute public parse -> resolve ->
prepare -> compile -> consume -> bind -> Analysis, including n/p DC sweeps, AC,
BE/TR transient, IC, RF gate/body/series nodes, output noise, M/NF separation,
condition mismatch, resource rejection, cancel and partial-owner cleanup. Prove
model-name lookup 0 after resolution, expression re-evaluation 0, candidate-range
copies 0 and duplicate cold setup 0 for identical conditions.

Original Sky130 adoption is per exact source/corner/wrapper/capability matrix.
Low-voltage, RF, ESD and high-voltage composed wrappers are different rows. A
wrapper requiring unsupported voltage-dependent resistor/diode behavior must
fail explicitly; its internal MOS success cannot mark that wrapper complete.
Each row fixes the actual include/library entry point, caller input profile,
dimension scale, seed, supplied geometry and corner. Do not impose the low-voltage
wrapper's caller-scale assumptions on differently expressed high-voltage inputs.
The 4.62 pfet stays outside 4.5 completion. Full original 4.5 kernel qualification
also needs non-Sky130 selector modes from the native proof matrix.

After lower contracts pass, revalidate IO/CLI, PDKKit, Xcircuite and Studio actual
consumers and migrate affected dependency pins in the same adoption change.
Numerical evidence is Native CPU only. Changes here do not require solver
algorithm replacement or imply physical process certification.

## B45-6 Coordinate and Admission Contract

| Coordinate | DC / AC | BE / trapezoidal | Noise gains |
|---|---|---|---|
| Physical voltage slots | Qualified physical G / G+jwC or NQS admittance | Original dynamic residual/J | Complex adjoint gains |
| Reserved deficit slot | Unit diagonal, zero RHS (not multiplied by M) | Separate scaled deficit argument; included in J*x-residual | Exactly zero |

The bound owner extracts the deficit from SolutionState separately and zeroes that
slot in every physical bias. History initialization starts from equilibrium
deficit zero. M scales electrical and dynamic equations once, while the reserved
static constraint is a coordinate fix. A transient session keeps the same C owner
and accepted 29-state bank until end. Stamps never accept history; accepted-bias
evaluate/commit is one locked operation.

Numeric-ID projection borrows resolved buffers and creates separate contiguous
model/instance buffers once. Schema authority routes M and IC to Devices; native
selectors go only to their own role. Projection capacity is temporary; the safe
owner's C allocation, Swift payload and diagnostics are retained. Charge the
activated stress ceiling exactly once inside safe preparation. Shared backing
diagnostic arrays in bound metadata and preparation records are retained views,
not another allocation. The run reservation covers fixed mapping and owner
collection payload in its existing per-instance envelope.

Failure diagnostics remain exact 4.5 structured values. A distinct immutable
NativeBSIM45PreparationRecord keeps them after consuming binding; CLI persists
the same record independently of 4.8.3 maintainer-warning metadata. Preparation
identity includes the C adaptation identity. The source .options stress ceiling
must match explicit execution conditions for both BSIM4 releases.

Native release owner performance is measured by
`tools/bsim45/verify_safe_owner.py --output <directory> --benchmark`. Darwin
interposition counts allocation-entry calls (which can include nested libc
entries), with a positive Swift allocation control. Assert zero such calls and
zero owner-sized callocs across continuous DC/AC/BE-commit/noise loops, after
explicit warmup. Preparation latency and allocations are separate. This does
not claim a speedup over another release or a process-wide allocation census.
Public parse/prepare/compile/bind/analysis tests separately prove actual setup
count, same-binding evaluation work and root reservation lifetime.
