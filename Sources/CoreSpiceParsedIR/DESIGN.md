# CoreSpiceParsedIR

## Purpose and Scope

This SwiftPM module owns parsed source values before domain admission. Its parent
is [CoreSpice](../../DESIGN.md); it has no child components.

## Responsibilities and Boundaries

Parsed values preserve source intent. Numeric source vectors retain their order;
parser syntax, scalar expression evaluation and device physics are separate owners.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Parsed input boundary | Source preservation is not numerical admission |
| [ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md) | used by | Parsed values and resistor source roles | SPICE syntax preservation | Declaration acceptance is not numerical admission |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | used by | Model references, separate parameter maps and expressions | Canonical IR translation | Scalar consumers reject vectors; runtime references remain expressions |

## Architecture

```mermaid
flowchart LR
  SPICE[Source syntax] --> Parsed[Parsed numeric vectors]
  Parsed --> Lowering[Canonical source parameters]
  Lowering --> Device[Strict waveform admission]
```

## Contracts and Invariants

`numericVector` is a Sendable/Hashable ordered value. It is preserved by SPICE
serialization and lowering as `ParameterValue.realVector`; it never becomes a
scalar default. Source descriptors own finite, strictly increasing PWL admission.

### Resistor Source Provenance

`ParsedComponent.resistorModelCandidate` records only an ambiguous bare positional
identifier from resistor source syntax. Braced, quoted and named numeric values
never acquire this metadata, even when their expression is a single identifier.
Parser and scoped/include lowering resolve a candidate against visible model
declarations; its same-shaped numeric expression is never sufficient evidence
for reclassification. Unresolved candidates serialize as bare tokens and retain
the metadata through subcircuit node remapping. This source-only metadata never
enters model coefficients or physical instance parameter maps.

`ModelType.resistor` preserves source identity `R`. Declaration intake does
not by itself establish numerical execution. `ParsedModel` retains the
declaration name, type, original parameter values and location independently of
whether an instance uses it. `ParsedComponent.modelName` retains a source model
reference; its `parameters` retain only the placed instance's supplied values.
Neither map is replaced by a merged parameter dictionary at this boundary.

Static parameter expressions and simulation-voltage-dependent expressions share
the existing parsed expression representation. ParsedIR does not resolve names,
choose a runtime device, compute geometry resistance, assign a nominal
temperature, or decide noise capability. Those responsibilities belong to
[Lowering](../CoreSpiceLowering/DESIGN.md) and the
[Native Devices execution contract](../CoreSpiceDevices/Devices/DESIGN.md#resistor-execution-contract).
Unknown numerical parameters can remain losslessly represented in an unused
declaration; source preservation does not authorize ignoring them when used.

Verification must inspect both maps and the model reference after public parsing
and serialization, then follow public lowering to the existing canonical
`ResolvedDeviceModel`/`Instance.parameters` boundary. A model reference cannot
be erased by an explicit instance `r=`. No new parsed expression family or
foundry-qualified model type is introduced by the resistor declaration.

## Verification and Change Impact

[SPICEIOEndToEndTests](../../Tests/CoreSpiceIOTests/SPICEIOEndToEndTests.swift)
executes voltage/current PWL parsing, serialization, lowering, binding and actual
CPU transient output. Changes require parser, lowering and scalar consumer checks.
