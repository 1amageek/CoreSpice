# CoreSpice OSDI Contracts

## Purpose and Scope

This portable SwiftPM module owns immutable OSDI integration values. Parent:
[CoreSpice](../../DESIGN.md). Child: [Binding](Binding/DESIGN.md).

## Responsibilities and Boundaries

The module preserves exact artifact and descriptor selection, explicitly typed
model/instance assignments, previous-state input, and copied setup facts. It does
not load libraries, infer foreign parameter types, execute callbacks, or own
executable resources. OSDIRuntime and COSDI are host runtime dependencies of
CoreSpiceOSDI only.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Separates portable values from host execution | Revalidate native composition when values change |
| [Binding](Binding/DESIGN.md) | child | Validated immutable inputs and receipt | Owns value meaning and constructor failures | Receipt is inspection evidence |
| [OSDIContracts](../../../../swift-osdi/Sources/OSDIContracts/DESIGN.md) | depends on | Typed parameters and prepared topology | Reuses portable S2 facts | No runtime import |
| [OSDI instances](../CoreSpiceIR/OSDIInstances/DESIGN.md) | used by | Staged transport | IR transports inputs and receipts | Preserve exact values in clones |

## Architecture

```text
CircuiteFoundation Core + OSDIContracts
    -> CoreSpiceOSDIContracts/Binding
        -> CoreSpiceIR/OSDIInstances
        -> CoreSpiceOSDI host preparation
```

## Contracts and Invariants

All integration values are immutable Sendable structs. A binding carries a
digest-bearing ArtifactReference, never a path as model identity. Model and
instance assignments remain separate. S2 metadata, rather than numeric spelling,
determines supported parameter names, aliases and types at runtime preparation.

## Verification and Change Impact

Focused contract tests reject invalid selection, wrong scopes, repeated assignment
names and nonfinite previous state. Receipt checks require exact state dimension
and copied parameter-fact uniqueness. IR tests preserve both stages through builder
reconstruction. Native execution tests own actual setup, binding, resource lifetime,
and numerical behavior. Compile-only checks do not prove those runtime contracts.
