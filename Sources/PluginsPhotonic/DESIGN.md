# PluginsPhotonic

## Purpose and Scope
Child of [CoreSpice](../../DESIGN.md); native 512-port photonic mesh execution.
Children: [IR](IR/DESIGN.md), [Compiler](Compiler/DESIGN.md),
[GPU](GPU/DESIGN.md), [Execution](Execution/DESIGN.md).

## Responsibilities and Boundaries
Own physical input validation, matrix compilation, checked GPU allocations and sweeps.
The backend owns Metal buffer/submission safety; no CPU fallback is supplied.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Production GPU domain | Execution composition | Physical qualification is separate |
| [CoreSpiceBackend](../CoreSpiceBackend/DESIGN.md) | depends on | Checked allocation and dispatch | GPU implementation | Metal execution is required |
| [IR](IR/DESIGN.md) | child | Mesh values | Input authority | Wavelength model semantics |
| [Compiler](Compiler/DESIGN.md) | child | Layer plans | Matrix generation | Validated IR only |
| [GPU](GPU/DESIGN.md) | child | Checked buffers | Resource sizing | Explicit limits |
| [Execution](Execution/DESIGN.md) | child | Sweep results | GPU orchestration | Finite terminal results |

## Architecture
```mermaid
flowchart LR
 Mesh --> Compiler --> Backend[CoreSpiceBackend Metal]
 Backend --> Readback --> Results[Finite sweep results]
```

## Contracts and Invariants
Each wavelength compiles the requested mesh, executes every layer over every
repetition and returns finite averaged complex amplitudes. Cancellation or failed
work emits a failed/cancelled terminal event rather than completed evidence.

## Verification and Change Impact
Actual xcodebuild Metal tests compare against independently calculated complex
matrix products, cover full and partial even/odd layers, sweep and multibatch paths.
