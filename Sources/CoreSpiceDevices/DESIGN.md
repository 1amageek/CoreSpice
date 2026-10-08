# CoreSpiceDevices

## Purpose and Scope

This SwiftPM module owns native electrical device binding and stamping. Its
parent is the [CoreSpice package](../../DESIGN.md), and its device implementation
children are [Devices](Devices/DESIGN.md), [BSIM3](BSIM3/DESIGN.md), and
[BSIM4](BSIM4/DESIGN.md).

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
| [ParsedIR](../CoreSpiceParsedIR/DESIGN.md) | coordinates with | Original model and instance source roles | Resistor declaration provenance | Unused declaration acceptance is not execution admission |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | used by | Device preparation and supported parameter roles | Canonical model/instance values and runtime dependencies | Model values must not be flattened into instance overrides |
| [Analysis](../CoreSpiceAnalysis/DESIGN.md) | used by | Fallible stamps and noise admission | Numerical execution and current PSD consumption | Unsupported requested noise cannot disappear from a successful result |

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

The [resistor execution contract](Devices/DESIGN.md#resistor-execution-contract)
is the authority for the implemented ideal and static model-backed R boundary
and the target runtime resistor profile in B8.6.5.4. This module composes that child through the existing
registry and BoundDevice/noise interfaces. Declaration parsing, device admission,
and process-model qualification are separate completion claims. The target
runtime contract is not a statement that the current implementation supports
voltage-dependent R; that binding path remains an explicit refusal.

L3 parameters and topology are immutable after binding. The bound device owns a
`TransientCapacitanceStore` whose accepted currents use `Mutex`; its read and
mutation paths are common across targets without conditional synchronization.
No external callback or I/O runs while the history lock is held.

## Verification and Change Impact

The [L3 behavioral suite](../../Tests/CoreSpiceDevicesTests/MOSL3ConsistencyTests.swift)
owns current, derivative, polarity, capacitance, registry, and analysis evidence.
Changes to stamping require revalidation of DC/AC/transient analyses and the
parent contract; parser/lowering model-level selection remains unchanged.

## Fallible execution and transient sessions

BoundDevice DC/AC/transient stamps and accepted-step commits are throwing protocol
requirements. Existing nonthrowing implementations satisfy those requirements.
TransientSessionDevice begins history from an initial SolutionState and ends it
on every analysis-scope exit. NoiseAnalysisAdmissionDevice rejects unsupported
noise before a result can be labeled successful. NoisyDevice contributes
fallible current PSDs through the checked noise contract owned by
[Analysis](../CoreSpiceAnalysis/DESIGN.md). Their BSIM3 ownership, lifecycle
and behavior are defined by the [BSIM3 component](BSIM3/DESIGN.md).

## BSIM4 composition

[BSIM4](BSIM4/DESIGN.md) owns exact Level54 preparation, explicit work policy,
full auxiliary mapping and checked DC/AC/transient sessions. Its correlated-noise
uses the [output-referred contract](OutputReferredNoise/DESIGN.md). Registry policy is runtime configuration, not physical IR.
