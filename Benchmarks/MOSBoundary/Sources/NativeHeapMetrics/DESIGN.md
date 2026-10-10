# NativeHeapMetrics

## Purpose and Scope

Darwin platform adapter for heap/RSS, dynamic hook capture and exact allocation/copy/content calibration. Parent: [benchmark](../../DESIGN.md). No children.

## Responsibilities and Boundaries

Own only this benchmark adapter; production semantics remain CoreSpice-owned.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Benchmark](../../DESIGN.md) | parent | Measurement scope/calibration | Composes the probe | Native CPU only |

## Architecture

```text
Benchmark process -> adapter -> actual production/OS APIs -> measured evidence
```

## Contracts and Invariants

Follow the parent measurement contract; failure never becomes a zero counter.

## State, Ownership, and Lifecycle

The process owns the loaded dylib and atomic capture-function pointer. Initialization
resolves that pointer before measurement; acquire/release publication protects reads.
Capture returns snapshots by value and retains no borrowed pointer. Calibration
owns its one allocation until exactly one `free`; stack buffers stay within the
call. All copy lengths fit their initialized 64-byte buffers, including overlapping
`memmove`; the original Darwin APIs own aliasing and allocator semantics.

## Failure, Concurrency, and Constraints

The single probe owns capture intervals. Missing hooks, failed snapshots, allocation,
content or counter calibration failures reject measurement. Heap statistics and RSS
remain distinct from hook byte arguments and capacity reservations. This platform
adapter does not provide WASM, Embedded, arm64e or cross-process evidence.

## Verification and Change Impact

The parent runner verifies calibrated success, numerical signatures and bounded
failure. Changes invalidate measurement evidence for this adapter.
