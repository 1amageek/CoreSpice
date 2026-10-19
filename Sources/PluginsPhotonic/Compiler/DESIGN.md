# Photonic Compiler

## Purpose and Scope
Child of [PluginsPhotonic](../DESIGN.md); owns the compiler responsibility.

## Responsibilities and Boundaries
Own transfer-matrix coefficients and layer plans derived from validated IR.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PluginsPhotonic](../DESIGN.md) | parent | Mesh execution | Module composition | Native Metal only |
| [CoreSpiceBackend](../../CoreSpiceBackend/DESIGN.md) | depends on | Checked CPU/GPU buffer access | Native execution | No CPU fallback |

## Architecture
```mermaid
flowchart LR
 IR --> Compiler --> GPU --> Execution
```

## Contracts and Invariants
Every accepted pair produces its specified complex transfer matrix; invalid mesh parameters fail before dispatch.

## Verification and Change Impact
[Photonic tests](../../../Tests/PluginsPhotonicTests) own closed-form coefficients,
actual Metal sweeps, finite aggregation, sizing failures and cancellation behavior.
Changed numerical/ownership assumptions require direct executor integration checks.
