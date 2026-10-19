# OSDI Adapter Behavioral Tests

## Purpose and Scope
Verify the CoreSpice OSDI circuit adapter, native model lifetime, topology projection,
and ordinary analysis stamps. Parent: [CoreSpice](../../DESIGN.md). Children:
[fixtures](Fixtures/DESIGN.md).

## Responsibilities and Boundaries
Execute actual adapter paths and compare physical equations or independent
exact-artifact references. Independent reference tools own numerical reference
generation; these tests do not qualify model physics or another model release.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Verification ownership | Circuit integration | Native CPU evidence |
| [Adapter](../../Sources/CoreSpiceOSDI/DESIGN.md) | depends on | Prepared circuit and model lifetime | Production path | Private coordinates remain observable |
| [Support](../CoreSpiceOSDITestSupport/DESIGN.md) | depends on | Exact manifest values | Input/reference decoding | Library identity differs from descriptor name |
| [Fixtures](Fixtures/DESIGN.md) | child | Frozen circuit inputs | Analytic and real model cases | Point evaluation is not a solved circuit |

## Architecture
```text
manifest library ID -> exact artifact record -> native provider -> adapter preparation
     -> circuit compiler / analysis -> all returned coordinates -> independent validation
```

## Contracts and Invariants
Each device selects its exact manifest library record. Releases sharing a
descriptor name must not substitute one another. `OSDIFamilyCircuitTests` checks
the selected library ID, artifact digest, and prepared binding before solving.
Successful circuit witnesses include all private coordinates and source currents;
failed references require explicit failure without completed results.

## Verification and Change Impact
Run the focused `OSDIFamilyCircuitTests` with an explicit
`CORESPICE_OSDI_DC_MANIFEST`. A changed artifact, parameter, topology, or numerical
policy requires its own reference capture. Native API and CLI integration remain
owned by their corresponding test targets.
