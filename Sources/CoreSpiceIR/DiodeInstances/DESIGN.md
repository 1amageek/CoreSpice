# Diode Instance Stages

## Purpose and Scope

Parent: [IR](../DESIGN.md). No children. Own canonical transport of diode stages.

## Responsibilities and Boundaries

D3 publishes a resolved stage. This stage does not authorize numerical execution;
prepared receipts and executable owners belong to D4 Devices and execution.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [IR](../DESIGN.md) | parent | Instance/Netlist clones | Canonical transport | Preserve the stage |
| [Input](../../CoreSpiceDiodeContracts/Input/DESIGN.md) | depends on | ResolvedDiodeInstance | Checked immutable input | No dictionary authority |
| [Resolution](../../CoreSpiceLowering/DiodeResolution/DESIGN.md) | used by | Resolved stage producer | One frozen evaluation | No numerical preparation |
| [Device](../../CoreSpiceDevices/Diode/DESIGN.md) | used by | Future prepared stage | Numerical owner | D3 alone must refuse binding |

## Architecture

```text
checked resolution -> DiodeInstanceStage.resolved -> Instance -> IR clones
                                                 -> compile/bind refusal
```

## Contracts and Invariants

The stage retains immutable resolved input. Source model and instance dictionaries
cannot override it. All IR copies preserve the stage. A resolved stage never becomes
an executable device by merely compiling topology or looking up a registry entry.

## Verification and Change Impact

DiodeIntegrationTests verifies public parse/lower, Netlist transport and compiler/
direct binding refusal. DiodeResolutionExecutionTests verifies native refusal before
allocation. D4 must extend this exact stage and consuming owner contract together.

## D4 Prepared Transport

DiodeInstanceStage adds a prepared inspection receipt. Both stages retain the
same resolved value. Compiler admits only a receipt matching the instance name,
law/schema, two terminals and no private topology for the initial law. Native
execution must still consume the prepared numerical owner; registry metadata
cannot bind a receipt or a raw dictionary. Source/IR clone paths preserve the
stage unchanged.
