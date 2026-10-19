# Analysis Completion

## Purpose and Scope

Completion is a caller-owned fallible barrier after numerical validation and device session release, before a completed event. Nested analyses omit the barrier; the full invocation alone finalizes.

## Responsibilities and Boundaries

This component owns its generic public boundary. Concrete callers own physics, resources and error diagnostics.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Parent](../../CoreSpiceAnalysis/DESIGN.md) | parent | Analysis/device composition | Invocation lifecycle | Preserve failure propagation |

## Architecture

```text
caller -> generic boundary -> validated acceptance or original failure
```

## Contracts and Invariants

AnalysisCompletionFinalizing.finalizeCompletion() throws
All requirements are Sendable. A thrown error prevents successful publication.

## State, Ownership, and Lifecycle

Values are immutable. Caller implementations own mutable state under their existing synchronization. Trial queries never advance accepted history.

## Failure, Concurrency, and Constraints

Nil candidate bound means no bound; a present bound is finite positive seconds. Session initialization is explicit, never inferred from time zero. Invocation limits admit scratch and records before retention.

## Verification and Change Impact

[Transient startup tests](../../../Tests/CoreSpiceAnalysisTests/TransientStartupContractTests.swift) and dynamic contract tests verify original failures, accepted history, candidate rejection and finalization ordering. Revalidate parent Analysis and bound session implementers when these contracts change.
