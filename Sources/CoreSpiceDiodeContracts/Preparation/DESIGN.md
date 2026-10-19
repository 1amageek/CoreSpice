# Diode Preparation Contract

## Purpose and Scope
Parent: [DiodeContracts](../DESIGN.md). The implementation resides in this directory and depends on checked [Input](../Input/DESIGN.md).
No children. Own preparation admission, semantic identity and inspection receipt.

## Responsibilities and Boundaries
Caller supplies an explicit environment, analysis capabilities and finite limits.
Devices owns numerical feature support and executable ownership. Contracts do not
claim numerical qualification or hold mutable executable state.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Input](../Input/DESIGN.md) | depends on | Checked model/instance values | Source-free and source-backed inputs | Source-free values never claim source capture |
| [Devices Diode](../../CoreSpiceDevices/Diode/DESIGN.md) | used by | Preparation identity and receipt | Consuming owner | Receipt copies cannot bind |

## Architecture
```text
checked resolution + environment + ordered terminals + analyses + limits
    -> numerical preparation owner -> receipt -> consuming bind
```

## Contracts and Invariants
Environment, profile/law, canonical coefficients and origins, instance geometry,
thermal request, declaration/provenance, ordered terminals and analysis set remain
bound in identity. Receipt construction is package-only. Native preparation
refuses unsupported physical features; the caller cannot claim feature support.
GenericJunctionV1 preserves the existing generic diode public profile while
coreJunctionV1 remains restricted to a memoryless junction. Both use the same
checked schema roles and ownership boundary. Unknown coefficients and nonzero Rs
are not erased. Numerical generic charge/breakdown qualification belongs to 07N.

## Verification and Change Impact
Preparation tests exercise environment/profile mismatch, AREA/M/temperature,
limits, cancellation, exact mapping, direct raw bind refusal and single setup.
Portable compile/link/runtime checks cover value identity and refusal, separately
from native numerical execution. Changes require IR and native admission review.
