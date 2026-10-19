# Frequency Noise

## Purpose and Scope
Parent: [Analysis](../DESIGN.md). Own input-referred quantity and generic residual-source transfer consumption within the existing NoiseAnalysis. No children.

## Responsibilities and Boundaries
Devices own scoped densities and source metadata. Analysis owns transfer, input normalization, retained PSD channels and actual OP evidence.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [ResidualNoise](../../CoreSpiceDevices/ResidualNoise/DESIGN.md) | depends on | Canonical endpoints and scoped PSD | Unit-aware independent transfer | No fabricated correlation |

## Architecture
```text
actual OP -> AC/noise matrix -> source injection -> output PSD -> input quantity and trapezoidal RMS
```

## Contracts and Invariants
Frequency matrices use the original device Jacobians without adding DC recovery
gmin. Recovery regularization may assist the operating-point search but cannot
change the final operating point, AC transfer or noise network. The three-row
FrequencyNoiseTests fixture has exact AC output -4 and noise transfer row
[1/2, -1/4, -3/10], giving PSD 9/4 + 1 + 9/4 = 11/2 even when
caller recovery gmin is 1/2.

Output is an electrical voltage difference; thermal output nodes are refused under explicit row policy. Input quantity distinguishes voltage and current source normalization. Residual source density and output-referred channel arrays retain stable metadata. Legacy independent current sources also retain their actual supplied A²/Hz density with a per-device ordered source index and canonical node endpoints; ground is nil. Correlated output-referred channels remain separate and do not fabricate a raw independent density. All values are finite and nonnegative. Channel and source-density capacity is admitted before retention through the existing storage/accounting owner.

## State, Ownership, and Lifecycle
One immutable metadata snapshot per device and frequency-independent transfer indices are retained for the sweep. PSD spans are borrowed only during synchronous consumption. The result retains actual OP and the storage lease. An attached OP must have the exact same canonical variable map as the frequency result; mismatched identity or row order throws AnalysisResultValidationError.variableMapMismatch before publication. Caller finalization precedes outer completed.

## Failure, Concurrency, and Constraints
Device, source-shape, unit, capacity and cancellation errors propagate. No I/O or evaluation runs under a new lock. Only native host execution evidence is claimed.

## Verification and Change Impact
FrequencyNoiseTests owns A/V/W/ground/collapse transfer, mode separation, canonical input branch, input quantity and completion failures. Native and CLI own original four-model execution and save/reload.
