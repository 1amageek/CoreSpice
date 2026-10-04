# CoreSpiceIR

## Purpose and Scope

This SwiftPM module owns canonical circuit values. Parent: [CoreSpice](../../DESIGN.md). This module has no newly introduced child components.

## Responsibilities and Boundaries

IR owns resolved model provenance and auxiliary node identity. Device physics and model admission belong to device implementations.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Owned module boundary | Revalidate direct consumers when contracts change |

## Architecture

```mermaid
flowchart LR
    Input[Typed inputs] --> Owner[CoreSpiceIR]
    Owner --> Output[Validated outputs or typed failure]
```

## Contracts and Invariants

`ResolvedDeviceModel` keeps model name, canonical type, and resolved parameters separate from instance parameters. `Instance.ownedNodes` are private auxiliary MNA variables; physical ports and read-only referenced nodes remain distinct. Netlist allocation creates fresh owned identities without resolving source-level node names. All owned nodes appear in CircuitIR.nodes. Conflicting diagnostic names fail build rather than aliasing private identities.

## State, Ownership, and Lifecycle

Values are Sendable. Netlist is an exclusively mutated builder; no shared mutable model state or C ABI enters this module.

## Failure, Concurrency, and Constraints

Invalid allocation requests and name collisions produce NetlistError. Owner identities survive cloning for parameter perturbation and Monte Carlo.

## Verification and Change Impact

BSIM3 integration tests trace provenance, private identities, and actual sparse topology. Revalidate Compile, Devices binding, Analysis composition, Lowering, and instance-copy consumers.
