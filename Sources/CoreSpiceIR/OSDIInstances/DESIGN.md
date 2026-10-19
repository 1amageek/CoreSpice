# OSDI Instance Stages

## Purpose and Scope

Parent: [CoreSpiceIR](../DESIGN.md). This component owns canonical transport of
OSDI resolved/prepared stages. No children.
Status: S3 source implemented; focused contract and transport verification is pending.

## Responsibilities and Boundaries

OSDIInstanceStage is resolved(OSDIResolvedInstance) or
prepared(OSDIPreparationReceipt). Instance.osdi is the sole OSDI binding and typed
assignment authority. Generic parameters/model maps and MOS release enums do not
replace these values. ModelConsumption retains its independent source provenance
responsibility.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [IR](../DESIGN.md) | parent | Instance and Netlist | Owns canonical circuit transport | Preserve stages in all reconstruction paths |
| [OSDI binding](../../CoreSpiceOSDIContracts/Binding/DESIGN.md) | depends on | Exact resolved input and receipt | Portable immutable authority | Receipt owns no executable resource |

## Architecture

```text
typed catalog -> resolved stage -> Instance/Netlist transport
    -> host setup/collapse -> prepared stage -> compile/bind
```

## Contracts and Invariants

The resolved accessor returns the exact input for either stage. Both Netlist
addInstance overloads and build reconstruction preserve Instance.osdi. Other IR
reconstruction consumers preserve the stage when OSDI semantic input is unchanged.
An input change requires a new validated resolved value and fresh preparation.
No OSDIRuntime/COSDI import or mutable executable state enters CoreSpiceIR.

## State, Ownership, and Lifecycle

Stages are immutable Sendable values. Executable owners remain in host preparation
and consuming binding; inspection stages do not prolong or recreate their lifetime.

## Verification and Change Impact

Focused tests transport resolved/prepared values through Netlist reconstruction,
including branch-reference resolution. Revalidate lowering, native preparation,
compiler admission and Analysis reconstruction whenever this stage changes.
