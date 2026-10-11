# Original-Source Process Measurements

## Purpose and Scope
Native Darwin test-process measurement adapter. Parent: [benchmark](../DESIGN.md).
No children. The runner executes the existing original Sky130 public-path tests.

## Responsibilities and Boundaries
Reuse the calibrated [interposer](../interposer/DESIGN.md) and
[heap metrics](../Sources/NativeHeapMetrics/DESIGN.md); own only process interval,
report file and calibration admission. No production or allocator behavior changes.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Benchmark](../DESIGN.md) | parent | Fresh-process proof | Original-input measurements | No speedup claim |
| [Interposer](../interposer/DESIGN.md) | depends on | Atomic capture and overflow rejection | All async worker threads counted | API-entry coverage only |

## Architecture
```text
Runner -> fresh test process -> constructor calibration -> exact-source 4 analyses
                                     -> destructor capture -> bounded JSON report
```

## Contracts and Invariants
A separate image performs existing 257-byte allocation / 101-byte copy calibration
before enabling the interval. Only an exclusive-created caller report file is used.
Missing interposer, failed calibration/capture, overflow or failed output rejects
measurement. The runner also requires completed tests and identical source digests,
model selection and numerical signatures with instrumentation disabled/enabled.

## State, Ownership, and Lifecycle
The constructor owns one file descriptor and baseline snapshot until destructor.
These fields are initialized before main and accessed after main; worker hooks
access only the interposer's existing atomic state. Stop/drain accounting before
heap observation and report I/O. Retain no source/user pointer. Close descriptor
once. Process failure without a complete report cannot issue evidence.

## Failure, Concurrency, and Constraints
Darwin Native CPU only; original inputs are opt-in and unchanged. Process deadline
120 seconds. Whole-process metrics include test/audit/runtime overhead. Inlined
copies, private allocator loops and zone entries retain the interposer's exclusions.
RSS highwater and heap live bytes are distinct from requested bytes and reservations.

## Verification and Change Impact
`../run_original.py` calibrates each child and compares its complete numerical
outputs against the uninstrumented child. Recheck on adapter/interposer/test changes.
