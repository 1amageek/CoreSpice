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
| [ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md) | used by | ParsedParameterValue | SPICE numeric PWL vectors | Preserve exact pair order |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | used by | Numeric vector payload | Canonical IR translation | Scalar consumers reject vectors |

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

## Verification and Change Impact

[SPICEIOEndToEndTests](../../Tests/CoreSpiceIOTests/SPICEIOEndToEndTests.swift)
executes voltage/current PWL parsing, serialization, lowering, binding and actual
CPU transient output. Changes require parser, lowering and scalar consumer checks.
