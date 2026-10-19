# CoreSpice Module

## Purpose and Scope

Parent: [CoreSpice package](../../DESIGN.md). Child:
[NativeExecution](NativeExecution/DESIGN.md), implemented for its explicit CPU capability. This existing SwiftPM module
owns public simulation composition and Foundation artifact result integration.

## Responsibilities and Boundaries

CoreSpiceSimulator currently composes an injected CoreSpiceSimulationBackend and
artifact-oriented request/result values. The native prepared path moves
numerical dispatch from the host to this domain module. The external process
backend retains its independent process semantics; profile-prepared native proof
cannot be generalized to it. PDK/flow/database authority remains outside CoreSpice.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Domain and artifact boundary | Direct developer API | No qualification claim |
| [NativeExecution](NativeExecution/DESIGN.md) | child | Checked preparation owner and concrete consuming analyses | Shared native numerical composition for API, CLI and host | Artifact backend execution remains separately injected |
| [IO](../CoreSpiceIO/DESIGN.md) | depends on | Checked source evaluation and simulation preparation | Domain source/intent intake | No reverse IO-to-CoreSpice dependency |

## Architecture

```text
artifact: CoreSpiceSimulator -> injected backend -> artifact result
native: IO resolved input -> common native owner -> consuming analysis -> completed facts
```

## Contracts and Invariants

Artifact references remain exact input/output data; caller-declared references do
not prove what a backend consumed. NativeExecution owns its actual observed input
and configuration identities. This module does not parse expected PDK contracts.
Package.swift explicitly depends on CoreSpiceIO and CoreSpiceWaveform, with no
reverse IO-to-CoreSpice edge. The electrical umbrella does not depend on or
reexport CoreSpiceBackend. GPU clients explicitly select that optional product;
its implementation is independent of the native Swift circuit algorithms.

## Verification and Change Impact

Existing CoreSpiceTests owns artifact/backend composition. Dedicated native tests
are indexed by the child. Child changes require actual native API/CLI/host callers;
external process behavior is rechecked only when its contract changes.
