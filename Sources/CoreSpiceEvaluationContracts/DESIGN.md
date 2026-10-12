# CoreSpiceEvaluationContracts

## Purpose and Scope

Status: D1 implemented and registered as a portable SwiftPM target. Source condition
bootstrap/freeze and consumer adoption remain D2-D5 work.
Parent: [CoreSpice](../../DESIGN.md). Child: [Environment](Environment/DESIGN.md).
Own the shared meaning of scalar evaluation conditions, independently of device physics.

## Responsibilities and Boundaries

Standard Library only, with no dependency on Foundation, IR, MOS, Devices or kernels.
The Environment child owns validated temperature values and condition identity.
Expression execution, option precedence and numerical preparation belong to consumers.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Target composition | Portable dependency floor | Only DiodeContracts currently consumes this target |
| [Environment](Environment/DESIGN.md) | child | Immutable checked environment | Shared temperature meaning | No device law |
| [Evaluation](../CoreSpiceMOSResolution/Evaluation/DESIGN.md) | used by | Frozen environment | Existing expression engine | Preserve one session/RNG |
| [Diode contracts](../CoreSpiceDiodeContracts/DESIGN.md) | used by | Condition identity and temperature types | Input/preparation agreement | No reverse dependency |

## Architecture

```text
Current: EvaluationContracts/Environment -> DiodeContracts
Planned D2-D5: Environment -> MOSResolution, Lowering, Devices, IO
```

## Contracts and Invariants

The child contract is the sole authority for units and identity. This target does not
contain an evaluator or import a device-owned OperatingConditions type.

## Verification and Change Impact

[CoreSpiceEvaluationContractsTests](../../Tests/CoreSpiceEvaluationContractsTests/EnvironmentTests.swift) builds without other local targets.
Native, normal WASM and Embedded WASM use fixed Swift 6.4.0/matching SDK compile,
link and minimal success/failure runtime evidence. These are value-contract proofs,
not numerical device or threading qualification.
