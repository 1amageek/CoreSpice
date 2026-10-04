# CoreSpiceDevices

## Purpose and Scope

This SwiftPM module owns native electrical device binding and stamping. Its
parent is the [CoreSpice package](../../DESIGN.md), and its device implementation
child is [Devices](Devices/DESIGN.md).

## Responsibilities and Boundaries

Descriptors validate model parameters and bind IR terminals to compiled indices.
Bound devices own physical currents, derivatives, capacitances, and accepted-step
history. Analyses own Newton iteration, factorization, timestep acceptance, and
typed numerical failures; devices never label an analysis successful.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Simulation domain | Package composition | Native evidence does not qualify a foundry model |
| [Devices](Devices/DESIGN.md) | child | Descriptors and bound devices | Physical models | Current and Jacobian must change together |

## Architecture

```mermaid
flowchart LR
    IR[Instance / compiled topology] --> Registry[DeviceRegistry]
    Registry --> Descriptor[DeviceDescriptor.bind]
    Descriptor --> Bound[BoundDevice]
    Bound --> Stamps[DC / AC / transient stamps]
    Stamps --> Analysis[CoreSpiceAnalysis]
    Analysis --> Commit[Accepted transient step]
    Commit --> History[TransientCapacitanceStore]
```

## Contracts and Invariants

`DeviceRegistry.standard()` selects concrete descriptors. Binding reports invalid
parameters through `DeviceBindingError`. L3 DC current residuals and AC real stamps
share the same derivative. Transient stamping combines that current with the
selected integration companion, and commits history only after acceptance.

## State, Ownership, and Lifecycle

L3 parameters and topology are immutable after binding. The bound device owns a
`TransientCapacitanceStore` whose accepted currents use `Mutex`; its read and
mutation paths are common across targets without conditional synchronization.
No external callback or I/O runs while the history lock is held.

## Verification and Change Impact

The [L3 behavioral suite](../../Tests/CoreSpiceDevicesTests/MOSL3ConsistencyTests.swift)
owns current, derivative, polarity, capacitance, registry, and analysis evidence.
Changes to stamping require revalidation of DC/AC/transient analyses and the
parent contract; parser/lowering model-level selection remains unchanged.
