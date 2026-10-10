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
