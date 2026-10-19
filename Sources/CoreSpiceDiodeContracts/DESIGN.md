# CoreSpiceDiodeContracts

## Purpose and Scope

Status: D1 checked scalar inputs/schema and D3 immutable resolved values are
implemented. D4 preparation values/receipts are implemented in the Preparation child;
native numerical and API/CLI adoption are owned by Devices and NativeExecution.
Parent: [CoreSpice](../../DESIGN.md). Children: [Input](Input/DESIGN.md), [Preparation](Preparation/DESIGN.md).
Own checked diode input/schema/stage contracts independently of numerical devices.

## Responsibilities and Boundaries

Depend only on [EvaluationContracts](../CoreSpiceEvaluationContracts/DESIGN.md).
No Foundation, ParsedIR, MOS, Devices, C or GPU dependency. Input owns coefficient
roles, normalization, feature requirements, staged values and typed failures.
Lowering owns source scope/expression resolution; Devices owns numerical admission.
A separate diode resolver target is unnecessary: Lowering already excludes Devices
and kernels, and its diode component can be tested without IO or an external tool.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Target composition | New pure target | Registered without adopting legacy diode paths |
| [Input](Input/DESIGN.md) | child | Schema and checked staged values | One role/unit authority | Recognition is not numerical support |
| [EvaluationContracts](../CoreSpiceEvaluationContracts/DESIGN.md) | depends on | Environment identity | Shared temperature meaning | No reverse edge |
| [Diode resolution](../CoreSpiceLowering/DiodeResolution/DESIGN.md) | used by | Input construction | Source-preserving interpretation | No dictionary merge |
| [Diode device](../CoreSpiceDevices/Diode/DESIGN.md) | used by | Checked resolution/preparation | Exact numerical admission | No raw-name fallback |
| [IR](../CoreSpiceIR/DESIGN.md) | used by | Diode stage reference | Canonical circuit transport | Preserve through clones |

## Architecture

```text
Current: EvaluationContracts -> DiodeContracts/Input
Implemented D3-D5 contract composition: DiodeContracts/Input -> IR, Lowering, Devices
```

## Contracts and Invariants

Checked construction and preparation stages follow the Input child contract.
D1 public checked numeric values are constructed only through validating factories.
For D3/D4 adoption, resolved/prepared receipts must likewise avoid unchecked public
memberwise initializers; those stages require their own adversarial integration tests.

## Verification and Change Impact

[CoreSpiceDiodeContractsTests](../../Tests/CoreSpiceDiodeContractsTests/DiodeSchemaTests.swift) is independent of the frontend and numerical
runtime. Verify fixed Swift 6.4.0 Native/WASM/Embedded compile/link/minimal runtime,
with no claim of portable numerical diode execution. Schema changes require both
resolver and Devices consumer evidence before public admission changes.

D4 preparation contracts are owned by [Preparation](Preparation/DESIGN.md).
