# CoreSpiceIR

## Purpose and Scope

This SwiftPM module owns canonical circuit values. Parent: [CoreSpice](../../DESIGN.md). Its MOS stage component is [MOS instances](MOSInstances/DESIGN.md).

## Responsibilities and Boundaries

IR owns resolved model provenance, stage-tagged MOS values, and auxiliary node identity. Device physics and model admission belong to device implementations.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [MOSInstances](MOSInstances/DESIGN.md) | child | Typed resolved/prepared MOS stage | Exact immutable value authority | Preserve when cloning |
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Owned module boundary | Revalidate direct consumers when contracts change |

## Architecture

```mermaid
flowchart LR
    Input[Typed inputs] --> Owner[CoreSpiceIR]
    Owner --> Output[Validated outputs or typed failure]
```

## Contracts and Invariants

### Selected declaration identity

ResolvedDeviceModel.declarationID is the opaque identity copied from the actual
selected parsed declaration. Nil means source origin is unavailable; it cannot
be reconstructed from name/type/parameters. It remains separate from physical
maps and survives instance cloning.
`Instance.modelConsumption` records unrecorded, explicitly model-free, or selected
source model consumption independently of physical `Instance.model`. Generated
elements retain the source model here while preserving their own physical maps. IO owns the origin inventory and bytes;
IR does not depend on ParsedIR, filesystem access or qualification schemas.


`ResolvedDeviceModel` keeps model name, canonical type, and resolved parameters separate from instance parameters. `Instance.ownedNodes` are private auxiliary MNA variables; physical ports and read-only referenced nodes remain distinct. Netlist allocation creates fresh owned identities without resolving source-level node names. All owned nodes appear in CircuitIR.nodes. Conflicting diagnostic names fail build rather than aliasing private identities.

## State, Ownership, and Lifecycle

Values are Sendable. Netlist is an exclusively mutated builder; no shared mutable model state or C ABI enters this module.

## Failure, Concurrency, and Constraints

Invalid allocation requests and name collisions produce NetlistError. Owner identities survive cloning for parameter perturbation and Monte Carlo.

## Verification and Change Impact

BSIM3 integration tests trace provenance, private identities, and actual sparse topology. Revalidate Compile, Devices binding, Analysis composition, Lowering, and instance-copy consumers.

## Typed Source Vector Input

`ParameterValue.realVector` preserves ordered numeric source input inside canonical
Netlist/Instance state. Independent source descriptors interpret `pwl` as alternating
time/value pairs; IR does not own waveform admission or device physics. Parsed IR,
SPICE parsing/serialization and lowering preserve this vector without scalarizing it.

## Runtime Ambient Variable Contract

The canonical behavioral-variable target includes ambient temperature in Celsius,
separate from time, canonical node voltage and branch-current references. Its
value is supplied by Devices binding from OperatingConditions, not captured as a
lowering-time constant. It creates no matrix dependency and no shared state.
[Devices runtime resistor contract](../CoreSpiceDevices/Devices/DESIGN.md#complete-admitted-runtime-resistor-profile)
owns the physical current/noise law; IR owns only this preserved meaning. The
variable is implemented as `BehavioralVariable.ambientTemperatureCelsius`; proof
remains B8.6.5.13-owned. IR/Lowering/device tests must verify
that one retained expression can be rebound at different operating temperatures.

## Designed Typed Diode Stage

Status: proposed. Depend on [DiodeContracts](../CoreSpiceDiodeContracts/DESIGN.md) and
transport `Instance.diode` as resolved input or immutable preparation receipt. The
[Input child contract](../CoreSpiceDiodeContracts/Input/DESIGN.md) owns its meaning.
Physical diode inputs must not be reconstructed from Instance.parameters/model maps.
Clone/replacement/perturbation consumers preserve a stage only when semantic input
is unchanged; changed input requires checked resolution and fresh preparation.
A prepared receipt is transport evidence, not executable ownership or bind permission.

Source-evaluated CircuitIR additionally retains the frozen evaluation environment
identity from the [Environment contract](../CoreSpiceEvaluationContracts/Environment/DESIGN.md).
Native preparation validates this circuit identity before any family-specific work;
this protects scalar non-MOS values too. All CircuitIR reconstruction paths preserve
it. Source-free typed circuits have a distinct programmatic origin; runtime ambient
variables keep their existing binding semantics and cannot masquerade as evaluated
source scalars. D2 owns this common stamp/entry guard; D5 verifies every transport.

## D2 Source Evaluation Environment Transport

CircuitIR optionally carries EvaluationEnvironmentIdentity. Non-nil means source
scalar values were evaluated under that frozen environment; absence is reserved
for source-free typed IR. Builders, clones, MOS topology preparation and compiler
ExecutionPlan transport preserve it. Whole-circuit binding compares both ambient
and nominal values before binding any device, even when no MOS exists. This stamp
is not a claim of numerical execution or physical accuracy.

## D3 Change Impact

The [D3 resolution owner](../CoreSpiceLowering/DiodeResolution/DESIGN.md) defines occurrence admission, frozen
evaluation, immutable result transport and explicit numerical refusal. This layer
consumes that contract; D4 numerical preparation and D5 downstream adoption remain
separate. Its affected production path and behavioral tests are verified in D3.

The [DiodeInstances child](DiodeInstances/DESIGN.md) owns staged diode transport.
