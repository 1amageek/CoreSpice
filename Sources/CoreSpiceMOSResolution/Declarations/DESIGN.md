# MOS Declaration Snapshot

## Purpose and Scope

Parent: [Resolution](../DESIGN.md). This component owns checked construction and
immutable indexing of declarations. It does not evaluate or select models.

## Responsibilities and Boundaries

The builder interns ASCII case-normalized names once, preserves every model
occurrence in source order, and freezes symbols/scopes/programs/bindings/functions.
Exact-name and family indices group declaration IDs into contiguous ranges while
leaving the canonical ordered declaration array unchanged. Family names consist
only of a nonempty base followed by a dot and one or more ASCII decimal digits.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Contracts](../../CoreSpiceMOSContracts/DESIGN.md) | depends on | IDs, programs, limits, failures | Portable snapshot data | No Foundation or Codable |
| [Resolution](../DESIGN.md) | used by | Ordered immutable indices | Nearest owner and exact priority | Selection remains resolver-owned |

## Architecture

```text
source occurrences -> builder(interner + ordered tables)
                   -> immutable snapshot + exact/family contiguous ID ranges
                   -> concrete resolver
```

## Contracts and Invariants

IDs are zero-based table indices. Parent scopes precede child scopes. Each binding
and function belongs to exactly one declared scope. Programs reference existing
symbols; coefficients reference existing programs and symbols. Duplicate model
occurrences are retained, never overwritten by a dictionary. Duplicate parameter
bindings remain ordered for profile-specific resolution. Index order is stable
within each family/exact name. Scope selection and duplicate policy are not
encoded by construction.

## State, Ownership, and Lifecycle

The builder exclusively owns mutable Swift values. finish returns a final immutable Sendable snapshot storage owner with O(1) identity; immutable arrays use COW ownership without borrowed pointers.
Index lookups return slices retaining their backing arrays. Construction uses
the explicit evaluation-step ceiling for its own identifier/node/index work, even
without an external controller. No shared mutable
state or session cache belongs here.

## Failure, Concurrency, and Constraints

Every append checks caller limits and UInt32 ID capacity before growth. Identifier
bytes, AST nodes/depth and index work cooperate with the explicit work controller.
Invalid references fail before snapshot publication. No partial snapshot is returned.

## Verification and Change Impact

MOSSnapshotTests verifies duplicate/case/source/scope preservation, contiguous
family/exact indices, dot-digit grammar and invalid/limited construction. Resolver
selection tests own nearest owner, exact priority and candidate policy.

### Capacity, source retention and failure state

One storage ledger owns the actual element capacities of all construction arrays,
the symbol dictionary's key/value capacity, nested binding/function/coefficient
arrays and the retained program payloads. Text payload is charged per retained
reference. Dictionary bucket metadata, owner bookkeeping and allocator overhead
are excluded, as specified by the [value accounting contract](../../CoreSpiceMOSContracts/Values/DESIGN.md#retained-payload-and-construction-capacity-accounting).

Each record's complete text/nested-array payload and prospective buffer growth
are preflighted together before charging. Ordinary preflight rejection leaves
retained-byte bookkeeping unchanged; consumed work is never rolled back.
Capacity reservation admits a conservative old-plus-new COW/growth peak and checks
the actual returned capacity before append. If a reservation or charge fails after
mutation may have started, the builder records that typed failure and rejects all
later mutation and finish entry points. No partial snapshot can escape that state.
Function-formal duplicate scratch has its own preflighted Set capacity before any
insertion; its lifetime ends before function record retention.

finish owns a local ledger and local exact/family/final-scope arrays. Failed finish
releases these buffers without adding phantom bytes to builder storage. Successful
publication counts every output capacity and drops the private construction-scope
array from the snapshot metric. Indices use in-place heap sort with typed work and
cancellation failures, without hidden sorting buffers.

Program construction receives the builder's remaining byte and work budget;
consumed work returns on success and failure. Identifier, model-family and index
scans share that invocation ceiling. Repeated programs cannot reset it.
