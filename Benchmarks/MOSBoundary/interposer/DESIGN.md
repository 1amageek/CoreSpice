# Process-local Allocation and Copy Evidence

## Purpose and Scope

Darwin platform adapter for calibrated allocation/copy API entries and requested
bytes in release child processes. Parent: [benchmark](../DESIGN.md). No children.

## Responsibilities and Boundaries

The dylib owns process-wide counters; the probe owns calibration/intervals; the
runner owns process timeout, source hashes and result comparison. Original Darwin
functions own buffers and actual copying. Hooks do not retain or inspect pointers,
allocate, log, lock, invoke callbacks or access TLS. Nested API entries are counted
separately; byte totals describe API arguments, not unique physical traffic.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Benchmark](../DESIGN.md) | parent | Calibrated scoped measurement | Actual production phases | Instrumented timing is separate |

## Architecture

```text
Child-only DYLD_INSERT_LIBRARIES -> original API + lock-free atomic counter
Probe capture -> close gate -> drain active hooks -> cumulative snapshot
```

## Contracts and Invariants

Each hook delegates once with the original prototype, overlap and size semantics.
Darwin dyld keeps the interposer image's references directed at original symbols.
The probe resolves capture before measurement. Volatile function-pointer calls
must observe one 257-byte malloc/free and five combined memcpy/memmove/bcopy-family entries,
101 copy bytes, including correct overlapping contents. Failure rejects evidence.
Darwin may alias memcpy/memmove and forward fortified calls into memmove. The
probe calls all five public functions through volatile pointers; hooks observe
only the unfortified family, calibrating five calls/101 bytes without duplicate
fortified entries. Names of wrappers cannot identify the original caller API.
Compiler-inlined/private loops and direct allocator zone APIs are outside coverage.

## State, Ownership, and Lifecycle

Process-local always-lock-free C11 atomics own counters/gate/in-flight hooks.
Capture closes the gate and waits at most 1,000,000 observations for active hooks;
no source buffer or external owner crosses the capture boundary. Copying the
snapshot while the gate is closed is excluded from measured intervals.

## Failure, Concurrency, and Constraints

Overflow, failed drain/calibration or pointer-authenticated arm64e function ABI
reject measurement. No global environment changes. Hooks retain no storage and
cannot outlive the child process. No asynchronous cleanup or hidden fallback.

## Verification and Change Impact

The parent runner builds this dylib, calibrates every instrumented child and checks
full DC signatures against uninstrumented children. Source or compiler changes
invalidate evidence. A loaded dylib alone is never accepted as calibration proof.
