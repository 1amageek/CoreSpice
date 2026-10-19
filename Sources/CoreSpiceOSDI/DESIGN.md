# CoreSpiceOSDI

## Purpose and Scope
Native-only OSDI equation adapter. Parent: [CoreSpice](../../DESIGN.md). Children:
[Preparation](Preparation/DESIGN.md), [Topology](Topology/DESIGN.md),
[DCExecution](DCExecution/DESIGN.md), [RangeExecution](RangeExecution/DESIGN.md).

## Responsibilities and Boundaries
Owns setup-to-IR projection and F/Q/G/C/noise contributions to the existing solver.
Artifact acquisition is injected; filesystem policy and numerical solving belong
to host composition and Analysis respectively. No model equations are copied.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Runtime](../../../swift-osdi/Sources/OSDIRuntime/DESIGN.md) | depends on | Exclusive point session | ABI owner | One isolated image per instance |
| [Devices](../CoreSpiceDevices/DESIGN.md) | depends on | BoundDevice, BindingContext | Existing stamp path | Foreign evaluation runs outside Mutex |
| [Continuous equation structure](../CoreSpiceDevices/ContinuousEquationStructure/DESIGN.md) | depends on | Package-only actual-device support visitor | Execution mapping witness | No circuit/physical certificate |
| [RangeExecution](RangeExecution/DESIGN.md) | child | Package conditional identity capture and controlled snapshot | Local source/mapping facts only | No global kernel, rank, root or history claim |
| [Values](../CoreSpiceOSDIContracts/DESIGN.md) | depends on | Exact binding and receipt | Immutable inspection | Receipt is not execution authority |

## Architecture
```text
injected exact artifact provider -> setup/collapse -> private IR coordinates
 -> compiler CSR -> consuming bind -> checkout session -> native equations -> existing stamp
```

## Contracts and Invariants
DC keeps supplied previous state fixed through every restamp. AC uses its explicit
native phase, and noise matrix/density evaluations use the distinct noise phase.
Transient initialization, trials and acceptance follow the authoritative
[execution contract](DCExecution/DESIGN.md). Collapse sums raw rows and
columns, ground is omitted, distinct external nets cannot collapse together.
V/A, A/V and K/W are admitted; all other natures fail. Library/storage lifetime
outlasts pointers, buffers close before image, and concurrent/reentrant use fails.

## Verification and Change Impact
Tests own nonlinear full-solution F/Q stamps, complex G/C, scoped native noise,
collapse/ground/flow projections, identity/mapping/nature/limits refusal,
accepted/trial state separation and exclusive cleanup.
Native composition owns complete solver and exact-artifact API/CLI tests.
