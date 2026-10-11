# Compact Model Preparation Storage

## Purpose and Scope

Parent: [CompactModels](../DESIGN.md). No children. Own local preparation payload
capacity/work accounting shared by the safe native evaluators.

## Responsibilities and Boundaries

Check caller ceilings and cancellation before requested collection allocation,
then check actual capacity before use. Track simultaneous live payload and peak
initialization temporary bytes. Existing configuration backing and allocator/Swift
heap metadata are excluded. C owner bytes belong to the C ABI query.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [BSIM3](../BSIM3/DESIGN.md) | used by | Checked initialization storage | Original safe owner | Preserve failure destruction |
| [BSIM4](../BSIM4/DESIGN.md) | used by | Checked initialization storage | Original safe owner | Preserve explicit stress work |
| [Portable preparation](../../CoreSpiceMOSContracts/Preparation/DESIGN.md) | depends on | Limits, control and typed failure | Native caller admission | No numerical dependency enters Contracts |

## Architecture

```text
explicit limits/control -> requested capacity check -> allocate
    -> actual capacity check -> use -> record peak and immutable metadata
```

## Contracts and Invariants

Parameter order, normalized-name sets, lowercased ASCII names, bounded diagnostic
text, split views and diagnostic values are counted while simultaneously live.
Retained diagnostic text is the sum of the emitted line payloads, excluding
discarded newline separators. Requested admission, actual-capacity admission and
published retained metrics use this same sum. The original C message string,
including its separators, belongs to temporary payload accounting.
Original parameter capacities and the 32768-byte C diagnostic capacity bound the
standalone API's explicit local policy. Runtime numerical calls remain unchanged.
Local work units cover parameter iteration, setup checkpoints and diagnostics.
Devices admits and charges the BSIM4 stress ceiling before invoking this storage
path; standalone callers retain the configuration's separate stress policy.

## State, Ownership, and Lifecycle

Accounting is local mutable value state during exclusive initialization. No shared
mutable storage, callback under the evaluator Mutex, retained reader or new runtime
wrapper is introduced. Published metrics are immutable.

## Failure, Concurrency, and Constraints

Overflow, capacity, work or cancellation throws before owner publication and
preserves exactly-once C destruction. No unlimited native policy is supplied.

## Verification and Change Impact

Safe and Devices tests cover low ceilings, actual nonempty diagnostics, bounded
parameter projection, cancellation and failure cleanup. Payload metric changes
require both safe evaluators and native preparation receipt revalidation.

BSIM45 borrows separate numeric-ID buffers instead of allocating name dictionaries.
Its uniqueness set and fixed diagnostic conversion are admitted before use and
actual capacities are rechecked. The same limit/work/cancellation contract applies;
C inline diagnostics are already included in the queried owner allocation. Swift
retained diagnostics and text are additional payload, never charged as C memory.
