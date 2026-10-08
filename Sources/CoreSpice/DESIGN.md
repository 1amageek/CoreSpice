# CoreSpice Module

## Purpose and Scope

Parent: [CoreSpice package](../../DESIGN.md). Child:
[NativeExecution](NativeExecution/DESIGN.md), proposed. This existing SwiftPM module
owns public simulation composition and Foundation artifact result integration.

## Responsibilities and Boundaries

CoreSpiceSimulator currently composes an injected CoreSpiceSimulationBackend and
artifact-oriented request/result values. The proposed native prepared path moves
numerical dispatch from the host to this domain module. The external process
backend retains its independent process semantics; profile-prepared native proof
cannot be generalized to it. PDK/flow/database authority remains outside CoreSpice.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Domain and artifact boundary | Direct developer API | No qualification claim |
| [NativeExecution](NativeExecution/DESIGN.md) | child | Proposed prepare/execute owner | Actual native numerical composition | Not implemented by current artifact backend protocol |
| [IO](../CoreSpiceIO/DESIGN.md) | proposed depends on | Owned simulation preparation | Domain source/intent intake | Add native SwiftPM dependency during implementation; no cycle |

## Architecture

```text
current: CoreSpiceSimulator -> injected backend -> artifact result
proposed: IO prepared input -> native prepared plan -> native execution -> domain output
```

## Contracts and Invariants

Artifact references remain exact input/output data; caller-declared references do
not prove what a backend consumed. NativeExecution owns its actual observed input
and configuration identities. This module does not parse expected PDK contracts.
Its current Package.swift has no CoreSpiceIO dependency; implementation must add
that edge and a CoreSpiceWaveform dependency, with no reverse IO-to-CoreSpice edge.

## Verification and Change Impact

Existing CoreSpiceTests owns artifact/backend composition. Proposed native tests
are indexed by the child. Child changes require actual native API/CLI/host callers;
external process behavior is rechecked only when its contract changes.
