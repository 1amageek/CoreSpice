# External Model Preparation

## Purpose and Scope

This component owns the resource-retaining IO adapter for explicitly selected
original-M external preparation. Parent: [CoreSpiceIO](../DESIGN.md).
Child: [MOSBinPreparation](MOSBinPreparation/DESIGN.md).
It does not select a source bin or implement model equations.

## Responsibilities and Boundaries

`SPICEExternalMOSPreparer` binds an immutable `ExternalMOSPreparing` implementation
to the caller's existing source-resource owner. Source identity, lexical candidates,
scalar evaluation and checked publication remain Lowering-owned. The separately
owned explicit MOS bin profile supplies descriptor-bound normalization semantics.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [IO](../DESIGN.md) | parent | Prepared source composition | Public IO adapter | No new parser or execution facade |
| [MOSBinPreparation](MOSBinPreparation/DESIGN.md) | child | Descriptor-bound normalization profile | Explicit bin, geometry and Given semantics | Numerical provider qualification is separate |
| [Frontend](../../CoreSpiceLowering/Frontend/DESIGN.md) | depends on | ExternalMOSPreparing and checked source facts | Original M admission | Preparation is not numerical qualification |
| [Simulation Preparation](../SimulationPreparation/DESIGN.md) | used by | Request selections and shared resources | Preserved through reprepare | Preserve exact source and caller accounting |

## Architecture

```text
Explicit descriptor-bound profile + source resource owner
    -> immutable SPICEExternalMOSPreparer with retained metadata reservation
    -> original-M Lowering request and scoped callbacks
    -> same profile result -> Lowering association checks
```

## Contracts and Invariants

The adapter's identity equals the delegated profile identity. Its metadata lease is
admitted before publication and retained through every copied request/provider
reference. It checks cancellation before and after preparation, and before each
scalar/work callback. It passes the original request unchanged and never creates a
new evaluator, RNG, source context or budget. The profile accounts its own immutable
metadata and temporary arrays through the same caller resource owner.

## State, Ownership, and Lifecycle

All adapter fields are immutable `Sendable` values. Mutable accounting remains in
the caller's synchronized `SPICESourceResourceAccounting`; no conditional platform
storage, raw state or unchecked Sendable conformance is introduced. The reservation
is released when the final adapter copy is released; a failed initializer retains no
lease. No foreign library or numerical session is opened by this component.

## Failure, Concurrency, and Constraints

Identity and byte arithmetic failures are typed. Source accounting failures and
profile failures propagate unchanged. Callbacks do not escape preparation. Shared
profiles must satisfy `ExternalMOSPreparing: Sendable`; concurrent source runs keep
independent Lowering evaluation sessions and traces.

## Verification and Change Impact

Dedicated IO tests exercise actual original-M parsed input, scoped callback values,
source association rejection, cancellation and lease release. Synthetic preparers
prove this source boundary only, never actual TT/provider qualification. Changes to
the callback, source association or source-resource contracts require rechecking
Frontend and Simulation Preparation callers. Numerical DAE, all-root/history and
STA obligations remain downstream.

Checked external preparation is framed into the effective-settings identity under
its own external-M domain. The framing includes original source coordinates and
terminal order, selected declaration/profile, actual evaluated scalar addresses and
bits, geometry/selection/Given facts and exact library/descriptor/typed assignments.
Existing preparations without external-M selections keep their current encoding.
The encoder replays immutable evidence only; it does not reevaluate expressions.
