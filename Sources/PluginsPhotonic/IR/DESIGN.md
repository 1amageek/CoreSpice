# Photonic IR

## Purpose and Scope
Child of [PluginsPhotonic](../DESIGN.md); owns the ir responsibility.

## Responsibilities and Boundaries
Own mesh parameters and wavelength phase semantics. Do not execute Metal.

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
All parameters and evaluated phases are finite. Dispersion is conventional
D=(1/c) dn_g/dλ in SI seconds/metre² at λ₀, c=299792458 m/s.
The local Taylor contract is Δφ=L[-2πn_gΔλ/λ₀² +
(2πn_g/λ₀³−πcD/λ₀²)Δλ²]. It includes the geometric curvature even when D=0.
Zero imbalance and λ=λ₀ preserve base phase exactly. Non-finite evaluation throws.
This local second-order model makes no higher-order or broadband material claim.

## Verification and Change Impact
[Photonic tests](../../../Tests/PluginsPhotonicTests) own closed-form coefficients,
actual Metal sweeps, finite aggregation, sizing failures and cancellation behavior.
Changed numerical/ownership assumptions require direct executor integration checks.
