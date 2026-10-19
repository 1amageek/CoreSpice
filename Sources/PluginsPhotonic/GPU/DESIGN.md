# Photonic GPU

## Purpose and Scope
Child of [PluginsPhotonic](../DESIGN.md); owns the gpu responsibility.

## Responsibilities and Boundaries
Own checked allocation sizing, batch limits and coefficient counts.

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
State size multiplication is overflow-checked and batchSize is in 1...maxBatchSize. Pair count is in 1...256.
Coefficient storage contains eight contiguous Float values (32 bytes) per matrix,
in m00_real/imag, m01_real/imag, m10_real/imag, m11_real/imag order. Imported C
structs remain CPU IR values; no retroactive BitwiseCopyable conformance is used.

## Verification and Change Impact
[Photonic tests](../../../Tests/PluginsPhotonicTests) own closed-form coefficients,
actual Metal sweeps, finite aggregation, sizing failures and cancellation behavior.
Changed numerical/ownership assumptions require direct executor integration checks.
