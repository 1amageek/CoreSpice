# Transient Acceptance

## Purpose and Scope

Transient validation owns a generic original-equation validation hook and accepted integration records. Device physics and native state remain outside Analysis.

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

TransientPhysicalResidualValidating.validate(state:integration:) throws; TransientAcceptedStep records actual time, step, method and previous step.
All requirements are Sendable. A thrown error prevents successful publication.

## State, Ownership, and Lifecycle

Values are immutable. Caller implementations own mutable state under their existing synchronization. Trial queries never advance accepted history.

## Failure, Concurrency, and Constraints

Nil candidate bound means no bound; a present bound is finite positive seconds. Session initialization is explicit, never inferred from time zero. Invocation limits admit scratch and records before retention.

## Verification and Change Impact

[Transient startup tests](../../../Tests/CoreSpiceAnalysisTests/TransientStartupContractTests.swift) and dynamic contract tests verify original failures, accepted history, candidate rejection and finalization ordering. Revalidate parent Analysis and bound session implementers when these contracts change.

## Direct nonlinear residual composition

`TransientPhysicalResidualEvaluating` refines the validation boundary with `accumulateResidual(state:integration:add:) throws`. A per-trial internal adapter captures the immutable accepted electrical vectors and integration context, then supplies original full-circuit equations to the existing Newton correction path. Every ordinary and GMIN transient solve receives the same adapter. The final `validate` hook remains before accepted commits and is independent of the Newton evaluator; callbacks never publish accepted native, charge or current history.
