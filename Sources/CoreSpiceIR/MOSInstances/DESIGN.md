# MOS Instance Stages

## Purpose and Scope

Parent: [IR](../DESIGN.md). This component owns a typed MOS resolution/preparation
reference in canonical Instance values. No children.

## Responsibilities and Boundaries

Lowering produces resolved stage. Execution composition replaces it with prepared
stage only after Devices returns an actual receipt and auxiliary nodes are allocated.
IR owns neither physics preparation nor model-name lookup.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Preparation contracts](../../CoreSpiceMOSContracts/Preparation/DESIGN.md) | depends on | Resolution and receipt | Immutable stage values | Receipt does not own kernel state |
| [Compile](../../CoreSpiceCompile/DESIGN.md) | used by | Prepared stage | Validates topology before compilation | Unprepared MOS is rejected |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | Stage transition | Owns prepare/compile/bind ordering | Preserve stage when cloning |

## Architecture

```text
Instance.mos.resolved -> execution-owned preparation -> Instance.mos.prepared
```

## Contracts and Invariants

MOSInstanceStage is resolved(ResolvedMOSInstance) or prepared(MOSPreparationReceipt).
Instance.mos is the sole MOS model and normalized instance-value authority. Generic
model/parameter dictionaries must not override it. All cloning sites preserve this
field. Prepared receipt identity must match the instance and its exact release/type;
owned nodes must equal the receipt auxiliary count and not alias physical ports.
Compiler rejects a MOS stage attached to a non-MOS type, legacy MOS without a
receipt, mismatched instance identity/release/polarity, or nodes absent from the
canonical circuit node inventory. Generic model/parameter data remains available
for non-MOS devices and cannot satisfy MOS admission.

## State, Ownership, and Lifecycle

IR values are immutable Sendable and contain no mutable device owner. The numerical
owner lives separately in the execution composition until consuming binding.

## Verification and Change Impact

IR tests verify both stages and cloning. Compiler tests reject resolved/legacy MOS,
wrong release/type and topology mismatch. Devices binding tests verify identity and
conditions against the receipt. Lowering and all Instance reconstruction sites must
be updated together when this contract changes.
