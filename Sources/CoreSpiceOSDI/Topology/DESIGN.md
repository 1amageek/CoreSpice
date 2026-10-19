# OSDI Topology

## Purpose and Scope
Child of [CoreSpiceOSDI](../DESIGN.md); owns Topology.

## Responsibilities and Boundaries
Implements its parent's adapter contract without owning physics or solver policy.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Adapter](../DESIGN.md) | parent | DC adapter contract | Native-only | Revalidate native consumers |

## Architecture
```text
setup -> fixed projection -> consuming binding -> exclusive evaluation
```

## Contracts and Invariants
See the single authoritative [adapter contract](../DESIGN.md#contracts-and-invariants).
Preparation bounds count and adapter bytes before allocation; runtime limits bound
native storage/workspace. Foreign evaluation and stamping execute outside locks.

## State, Ownership, and Lifecycle
Prepared owners are noncopyable. Bound references share only an exclusive checkout
owner; explicit close destroys evaluator buffers before unloading its image.

## Failure, Concurrency, and Constraints
Typed failure preserves native cleanup owners and primary/secondary errors.
No candidate state is committed by DC evaluation. Cancellation closes unpublished
owners; concurrent/reentrant stamp or close returns busy.

## Verification and Change Impact
[Adapter tests](../../../Tests/CoreSpiceOSDITests) verify this child contract.
Parent NativeExecution verifies circuit composition and completed result cleanup.

### Connected terminal prefix

The caller connects a prefix of zero through `descriptor.terminalCount` terminals,
matching the S2 setup contract. Remaining trailing terminals participate as private
active coordinates after generated setup/collapse. This includes unconnected K/W
thermal terminals: they remain temperature-rise unknowns rather than being tied
to ground. More connections than descriptor terminals fail before native setup.
Full-count existing inputs preserve their previous projection. CMG/IMG selfheat
fixtures qualify the optional thermal prefix; topology and native execution tests
reject excessive terminal counts.
