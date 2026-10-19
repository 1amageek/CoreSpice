# CoreSpice Process Backend

## Purpose and Scope
Parent: [CoreSpice](../../DESIGN.md). No children. Own optional host process
invocation and captured simulator evidence. Native CoreSpice remains primary.

## Responsibilities and Boundaries
Delegate child/group lifecycle to SignoffToolSupport. Persist exact stdout/stderr
bytes and propagate the original typed execution cause. Keep pending cleanup
ownership in the thrown failure rather than dropping or stringifying it.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [SignoffToolSupport](../../../SignoffToolSupport/DESIGN.md) | depends on | TimedProcessRunning, TimedProcessFailure, cleanup handle | Bounded process-tree execution | A pending handle requires close or explicit transfer |
| [CoreSpice](../../DESIGN.md) | parent | Optional external evidence | Captured process artifacts | Process success does not issue qualification |

## Architecture
```text
invocation -> TimedProcessRunning -> raw bytes -> immutable output files
                                 -> typed failure -> bounded cleanup close
                                                  -> pending handle transfer
```

## Contracts and Invariants
Default host policy admits at most 64 MiB output, 300 seconds execution and
2 seconds cleanup/retry. An injected runner owns its explicit execution policy.
Output-limit/timeout/cancel/IO/control failures preserve TimedProcessFailure and
its original Data bytes. The adapter retries a pending cleanup handle under a
2-second bound before returning; if still pending the typed thrown failure retains
that exact handle. Persistence failure also retains the original process failure.
No decoding/re-encoding changes invalid UTF-8 evidence. Successful capture returns
only after delegated bounded cleanup. One actor invocation runs at a time.

## State, Ownership, and Lifecycle
The runner actor owns invocation admission. SignoffToolSupport owns process/group
signals and pipe capture. The caller owns any pending cleanup handle transferred
in CoreSpiceProcessBackendError; throwing cannot claim clean shutdown.

## Failure, Concurrency, and Constraints
First execution cause is retained if cleanup also fails. Cancellation with process
failure returns typed cancellation cause plus retained raw files; prelaunch Task
cancellation remains CancellationError. No public callback runs under a Mutex.

## Verification and Change Impact
Process backend tests run a real child and cancellation plus injected binary
failure/persistence cases. Recheck downstream error projections for typed failure
and explicit cleanup ownership, without promoting external execution to trust.
