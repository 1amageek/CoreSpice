# CoreSpiceBackend

## Purpose and Scope
Optional native Metal execution product/module, child of the [CoreSpice package](../../DESIGN.md).
Its [MetalExecution component](MetalExecution/DESIGN.md) owns storage and submissions.

## Responsibilities and Boundaries
Own typed buffer allocation, exclusive CPU borrows, GPU dispatch and completion.
Photonic numerical compilation belongs to [PluginsPhotonic](../PluginsPhotonic/DESIGN.md).

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice package](../../DESIGN.md) | parent | Explicit optional backend product | Native GPU execution | Electrical CoreSpice/Analysis/CLI do not depend on or reexport this module; no CPU fallback |
| [MetalExecution](MetalExecution/DESIGN.md) | child | Checked storage and submissions | Metal implementation | Raw storage does not escape |
| [PluginsPhotonic](../PluginsPhotonic/DESIGN.md) | used by | Layer dispatch | Photonic execution | 512 ports only |

## Architecture
```mermaid
flowchart LR
 API[ComputeBackend] --> Owner[MetalBuffer]
 Owner --> Metal[MetalExecution]
 Metal --> Queue[Metal command queue]
```

## Contracts and Invariants
CPU buffer elements provide a valid zero value and are bitwise-copyable Sendable values.
Released handles reject new work; CPU borrows and GPU work cannot overlap.
All previous submitted work is completed and its failure reported by synchronize.
MZI dispatch validates pattern, pair count, offset, batch arithmetic and capacities.

## Verification and Change Impact
[Backend tests](../../Tests/CoreSpiceBackendTests) execute actual production Metal.
Changing allocation or dispatch requires photonic executor integration tests.
