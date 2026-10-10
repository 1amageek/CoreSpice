# MOSPerformanceProbe

## Purpose and Scope

Executable entry point and benchmark-only policy/resource/control adapters; executes actual production resolution and native DC. Parent: [benchmark](../../DESIGN.md). No children.

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

## Verification and Change Impact

The parent runner verifies calibrated success, numerical signatures and bounded
failure. Changes invalidate measurement evidence for this adapter.
