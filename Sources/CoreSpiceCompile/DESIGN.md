# CoreSpiceCompile

## Purpose and Scope

This SwiftPM module owns sparse topology and numerical compile products. Parent: [CoreSpice](../../DESIGN.md). This module has no newly introduced child components.

## Responsibilities and Boundaries

Compilation consumes canonical node and branch connectivity; it does not infer compact-model auxiliary topology.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Owned module boundary | Revalidate direct consumers when contracts change |

## Architecture

```mermaid
flowchart LR
    Input[Typed inputs] --> Owner[CoreSpiceCompile]
    Owner --> Output[Validated outputs or typed failure]
```

## Contracts and Invariants

All physical, owned auxiliary, and referenced node pairs receive the required local CSR entries. Auxiliary variables have ordinary MNA indices and are never collapsed into physical ports.

## State, Ownership, and Lifecycle

Compiled topology is an immutable Sendable value. Runtime sparse matrices are exclusively mutated by the analysis.

## Failure, Concurrency, and Constraints

Device binding validates the required auxiliary ownership and topology before numerical execution.

## Verification and Change Impact

Integration tests inspect every required BSIM3 local sparse entry and execute CPU SparseLU on series/NQS circuits. Revalidate device binding and analyses when topology changes.
