# Residual Noise

## Purpose and Scope
Parent: [Devices](../DESIGN.md). Own generic residual-equation noise metadata and scoped density borrowing. No children.

## Responsibilities and Boundaries
A device owns immutable source order, stable descriptor indices, canonical endpoints and fresh per-frequency densities. Analysis owns circuit transfer and result admission. No raw foreign indices or numerical solver cross this boundary.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../../CoreSpiceAnalysis/DESIGN.md) | used by | Complex factorization and unit-row injection | Independent source PSD | Preserve the legacy correlated single accounting path |

## Architecture
```text
prepared source metadata -> scoped fresh PSD span -> canonical +/- equation injection -> complex solve -> output V²/Hz
```

## Contracts and Invariants
ResidualNoiseSource endpoints are canonical MNA variables or nil ground. Unit is the equation residual unit A, V or W; density uses its square per Hz. Density count equals metadata count, values are finite and nonnegative, and the callback runs exactly once synchronously. Borrowed spans never escape. Source indices are unique and stable, including zero or collapsed sources. Coincident endpoints cancel additively. NoiseMatrixStampingDevice separates noise-matrix context from pure AC.

## State, Ownership, and Lifecycle
Devices retain metadata and their prepared density buffer. Analysis borrows densities at the actual operating point and Hz without copying an ABI result array. Foreign evaluation and callbacks execute outside owner locks. No shared state or conditional synchronization is introduced.

## Failure, Concurrency, and Constraints
Unknown endpoints, wrong units, invalid counts/PSD, duplicate indices, callback misuse and device errors fail explicitly. Native composition admits actual retained channel capacity before allocation. Legacy NoisyDevice and OutputReferredNoisyDevice keep their existing contracts; one device follows one accounting path.

## Verification and Change Impact
Analysis frequency/noise tests own A/V/W injection, collapse/ground, actual OP and mode selection, invalid spectra and finalization failures. OSDI owns raw mapping and fresh ABI evaluation; native integration owns byte admission and lifetime.
