# CoreSpiceCLICore

## Purpose and Scope

This SwiftPM library module owns batch/interactive SPICE execution and reproducible
run records. Parent: [CoreSpice](../../DESIGN.md). It has no child design units.

## Responsibilities and Boundaries

Session loads the production deck gate, resolves analysis options, lowers,
compiles and binds, then calls public analysis APIs. Domain physics belongs to
Devices and its evaluators. This change owns explicit BSIM4 preparation policy
and immutable qualification provenance throughout initial and repeated binding.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | CLI artifacts | Developer execution surface | Success records require actual execution |
| [IO](../CoreSpiceIO/DESIGN.md) | depends on | Resolved SPICEAnalysisOptions | One policy source | No implicit model work budget |
| [Devices BSIM4](../CoreSpiceDevices/BSIM4/DESIGN.md) | depends on | Native registry and diagnostics | Original Level54 | Successful execution does not assert qualification |

## Architecture

`deck explicit option -> resolved options -> lowering + configured registry -> analysis -> run record`

## Contracts and Invariants

The actual deck option bsim4stressiterations is the caller's positive UInt32 work
budget. Session uses one resolved options object for lowering, initial binding,
source-sweep/MonteCarlo/sensitivity rebinding and operating conditions. The batch
record preserves effective policy separately from physical IR and retains BSIM4
initial-binding structured diagnostics and immutable maintainer qualification
limitations. Each model record names its initial-binding phase; Monte Carlo
rebindings share the policy but their varying diagnostics are not claimed by that
initial snapshot.
Missing/invalid policy and unsupported noise remain failed JSON records.

## State, Ownership, and Lifecycle

Session is a caller-owned value. Bound model shared state retains its existing
common Mutex owner; CLI introduces no mutable global or platform synchronization
branch. Each public analysis owns cancellation and transient-session cleanup.

## Failure, Concurrency, and Constraints

No unknown version/model failure becomes a successful fallback. CPU SparseLUSolver
and ComplexSparseLUSolver are the actual electrical execution path in Session;
merely importing Backend does not execute Metal. This evidence is host CPU only.

## Verification and Change Impact

CoreSpiceCLITests owns actual batch success/effective-policy records and typed
missing/invalid/version/noise failures. CoreSpiceBSIM4IntegrationTests owns public
analysis/session proof. Revalidate existing options/CLI consumers after convergence.
