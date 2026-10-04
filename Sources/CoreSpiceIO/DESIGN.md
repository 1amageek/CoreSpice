# CoreSpiceIO

## Purpose and Scope

This SwiftPM module composes SPICE parsing/lowering, analysis intent and waveform
I/O. Parent: [CoreSpice](../../DESIGN.md). This change owns explicit transient policy
selection; it introduces no child components.

## Responsibilities and Boundaries

`SPICEAnalysisOptions` translates parsed deck options into analysis configuration.
The caller owns resource ceilings. IO never selects an implicit unbounded or
machine-capacity execution policy. Numerical admission belongs to Analysis.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Public package composition | Developer/CLI input | Missing policy is a typed failure |
| [Analysis](../CoreSpiceAnalysis/DESIGN.md) | depends on | TransientExecutionLimits and config | Whole-run admission | DC and recovery share the same budget |
| [ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md) | depends on | Parsed controls and PWL | Source intent preservation | Malformed sources cannot execute as DC |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | depends on | Canonical source vectors | Device admission boundary | Preserve numeric pair order |

## Architecture

```mermaid
flowchart LR
  Deck[SPICE options or typed caller policy] --> IO[SPICEAnalysisOptions]
  IO --> Config[TransientConfig with explicit limits]
  Config --> Run[Budgeted CPU execution]
  Run --> Result[Exact waveform and execution statistics]
```

## Contracts and Invariants

Typed callers supply `executionLimits` directly. CLI/deck callers supply all seven
positive integer options: `tranmaxaccepted`, `tranmaxattempts`, `tranmaxiterations`,
`tranmaxscalars`, `tranmaxdimension`, `tranmaxwork`, `tranmaxbreakpoints`. Each option
has the corresponding Analysis limit meaning. Partial policy remains absent and
transient configuration fails with `missingExecutionLimits`. Option coverage can
inspect one option independently without fabricating a complete execution policy.
`executionLimitOptionsPresent` records whether the source declares any budget option;
callers distinguish absent policy from partial policy before selecting their own limits.
Scalar options and measurements reject numeric vectors.

## Failure, Concurrency, and Constraints

The options object is a Sendable value; it owns no shared mutable state. Missing,
invalid or exhausted policy remains typed and produces CLI JSON failure. CPU
waveform success does not imply Metal, WASM or Embedded qualification.

## Verification and Change Impact

[SPICEIOEndToEndTests](../../Tests/CoreSpiceIOTests/SPICEIOEndToEndTests.swift)
verifies voltage/current PWL roundtrip and actual execution, invalid source rejection,
complete policy resolution and missing policy. CLI fixtures explicitly own their
finite validation policy; changed defaults require direct API/CLI caller migration.

## BSIM4 preparation policy composition

SPICEAnalysisOptions resolves explicit `.options bsim4stressiterations=<positive UInt32>`
once into [BSIM4PreparationPolicy](../CoreSpiceDevices/BSIM4/DESIGN.md). Missing
policy remains nil and Level54 preparation fails typed. Malformed/zero/overflow
values fail; no fallback selects a budget. The same options value supplies both
loweringConfiguration and deviceRegistry, including every CLI rebind. Runtime
policy and kernel qualification diagnostics belong to execution provenance,
not physical model IR. Other model families do not require this policy.

## BSIM4 Noise Preparation Intent

SPICEAnalysisOptions resolves parsed .noise intent into one explicit
bsim4NoisePreparationRequested choice. The same options owner supplies lowering
Configuration and deviceRegistry, including CLI source overrides/Monte Carlo/
sensitivity rebinds. The choice is execution provenance, not model IR. Direct
API callers may request noise capability before lowering/binding; late requests
on electrical-only topology fail explicitly.
