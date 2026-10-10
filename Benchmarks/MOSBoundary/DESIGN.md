# MOS Boundary Performance Evidence

## Purpose and Scope

Reproducible Native CPU release measurements of original-string parsing through
resolution, one native preparation/binding and a five-point DC sweep. Parent:
[CoreSpice](../../DESIGN.md). Children: [probe](Sources/MOSPerformanceProbe/DESIGN.md),
[heap metrics](Sources/NativeHeapMetrics/DESIGN.md), [interposer](interposer/DESIGN.md).

## Responsibilities and Boundaries

This standalone benchmark package owns measurements, calibration and exact source
hashes. It does not change production dispatch, policy ceilings, numerical physics
or process qualification. Cold runs use fresh processes; reuse shares the immutable
compiled snapshot and creates a fresh evaluation session and prepared owner.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent / depends on | Parser, resolution and consuming native execution | Actual production path | Local package dependency is benchmark-only |
| [Native execution](../../Sources/CoreSpice/NativeExecution/DESIGN.md) | depends on | Preparation leases and completed DC facts | Measures same owner path as callers | Reservations are not measured heap bytes |

## Architecture

```text
Runner -> new release process -> parser -> snapshot -> resolve -> prepare/bind -> DC
                                   |         calibrated allocator/copy API hooks
                                   +-------- source/phase/resource/numerical evidence
```

## Contracts and Invariants

Allocation API calls/requested bytes and copy API calls/requested bytes are measured
separately from heap live bytes/RSS and logical resource reservations. Copy coverage
is the `memcpy`/`memmove`/`bcopy` entry family (including runtime aliases).
Fortified APIs are not separately interposed; calibration verifies their actual
forwarding into this observed boundary, avoiding duplicate fortified/internal
counting. compiler-inlined copies and private runtime loops are outside
this metric. This explicit API-boundary metric replaces the formerly unavailable
copy metric; it is not a claim of all physical memory traffic or zero global copies.
Five known calls (including both fortified APIs) and 101 bytes with their content
effects must calibrate exactly before each
instrumented child. Numerical signatures must equal uninstrumented signatures.
Structural obligations (no model re-search, binding re-evaluation, candidate-range
materialization or repeated cold setup) require source review plus the existing
control/resource/receipt assertions, not zero counts across the entire pipeline.

## State, Ownership, and Lifecycle

The child owns counters. No hook allocates memory or captures source/user pointers.
The probe retains original input/snapshot owners and consumes fresh prepared owners.
Each phase captures cumulative counters; deltas are overflow checked. Measurements
cover uninterrupted production phases with identical instrumentation settings.

## Failure, Concurrency, and Constraints

Toolchain is Swift 6.4.0 release on macOS; child timeout is 60 seconds. Hooks use
lock-free atomics and never allocate or access thread-local storage. Capture disables new accounting
and waits for active hooks with a finite bound; failure/overflow rejects evidence.
Instrumented timing is never mixed with uninstrumented timing. No portable numerical,
GPU, external simulator or process-accuracy evidence is issued.

## Verification and Change Impact

`run.py --output <new-directory> --scratch-path <path>` builds release, calibrates,
runs cold/reuse for Level 1, BSIM3 3.3.0 and BSIM4 4.8.3, and checks all signatures,
phase counters and source hashes. Each subprocess is bounded and logged. Re-run on
production source or harness changes. Native preparation tests own quota/cleanup;
this package measures their composed runtime, rather than replacing those proofs.
