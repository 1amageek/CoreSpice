# CoreSpiceMOSContracts

## Purpose and Scope

This Standard-Library-only module owns immutable MOS resolution contracts. Parent:
[CoreSpice](../../DESIGN.md). Children: [Values](Values/DESIGN.md) and
[Schema](Schema/DESIGN.md) and [Preparation](Preparation/DESIGN.md). Foundation, Codable, device kernels, parsing and
evaluation sessions are outside this module.

## Responsibilities and Boundaries

Values preserve explicit input profiles, identifiers, bound expression programs,
source occurrences, requested inputs and checked resolution results. Schema is
the single authority for release identities and parameter-specific input scaling.
The concrete resolver owns all algorithms and its noncopyable evaluation session;
no algorithm protocol permits replacing normalization or model selection.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Schema](Schema/DESIGN.md) | child | Exact release/role/kind/scaling contracts | Portable input meaning | Execution capability belongs to provider |
| [Preparation](Preparation/DESIGN.md) | child | Explicit preparation conditions/identity/topology | Portable execution boundary values | No numerical owner |
| [Resolution declarations](../CoreSpiceMOSResolution/Declarations/DESIGN.md) | used by | Immutable IDs and programs | Ordered snapshot construction | IDs are snapshot-local |
| [Devices](../CoreSpiceDevices/DESIGN.md) | used by | Exact release and normalized values | Preparation consumes resolution | Inspectable does not mean executable |

## Architecture

```text
Explicit profile + immutable declarations -> concrete resolver -> checked result
                       |                           |
                   Values IDs                  shared Schema
```

## Contracts and Invariants

Both coreStrictV1 and the normal ngspice profile pinned to
ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6 are explicit values. No implicit profile,
release substitution, content digest invention or numerical model implementation
is introduced. All stored production state is immutable and Sendable.

## Verification and Change Impact

CoreSpiceMOSContractsTests owns release/schema/scaling/checked-result failures.
CoreSpiceMOSResolutionTests owns snapshot integrity and source order. Parent owns
Native, WASM and Embedded compile/link/runtime capability verification.

Embedded executable composition explicitly links the matching SDK standard-library
`libswiftUnicodeDataTables.a`: String operations retain Unicode support even when
admitted identifiers are ASCII. The link/runtime probe records the exact SDK
library identity. This is a standard-library runtime requirement, not a
Foundation, numerical-kernel or Metal dependency.
