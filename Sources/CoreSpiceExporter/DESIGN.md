# CoreSpiceExporter

## Purpose and Scope

Parent: [CoreSpice package](../../DESIGN.md). No children. Own shared export contracts and atomic output lifecycle.

## Responsibilities and Boundaries

Supply the format-neutral output owner and configuration. Numerical analysis and waveform storage remain caller-owned.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Export composition | Package entry point | No solver qualification |
| [CSV](../CoreSpiceExporterCSV/DESIGN.md) | used by | Session operation serialization | CSV formatting | Mandatory header escaping |
| [RAW](../CoreSpiceExporterRAW/DESIGN.md) | used by | Session operation serialization | RAW formatting | Binary and ASCII rows |
| [PSF](../CoreSpiceExporterPSF/DESIGN.md) | used by | Session operation serialization | PSF formatting | Exact declared count |

## Architecture

```text
WaveformReadable -> session actor -> exclusive output helper -> partial file -> atomic publication
                               -> Mutex point-count snapshot
```

## Contracts and Invariants

One actor operation validates and writes a complete point, including the first
header, before publishing its point count. Finalize and cancel use the same actor.
The helper is non-Sendable and must have one owner; format sessions serialize
complete operations. Memory export retains the requested output; file export
retains one format row/header and at most 64 KiB per filesystem write. The exporter
does not materialize all waveform samples. Full-waveform export enters its session
actor once and performs its existing synchronous row loop there.

## State, Ownership, and Lifecycle

The session actor exclusively owns format state and its non-Sendable synchronous
output helper. The only shared snapshot is the point count protected by Mutex.
No waveform callback, external callback or filesystem operation runs under Mutex.
Open output is unpublished; finalize checks exact declared count and cancellation,
closes and synchronizes the temporary file, then atomically replaces or moves it.
Cancel/failure removes only that temporary file and never an existing destination.
Publication is the linearization point: cancellation observed before it prevents
success; cancellation arriving after it does not revoke already committed output.
Task cancellation is checked before creation, per point and between output chunks
of at most 64 KiB. A session that owns a failed or cancelled output cannot publish.

## Failure, Concurrency, and Constraints

| Boundary | Observable failure | Retained state |
|---|---|---|
| Invalid width, kind or finite sweep | `ExporterError.streamingError` | Prior complete points; no new row |
| Declared count mismatch | `ExporterError.streamingError` | Output discarded |
| Observed task cancellation | `CancellationError` | Output discarded; prior destination preserved |
| Write or publication I/O | Throwing I/O or `ExporterError.writeFailed` | Output discarded; prior destination preserved |
| Explicit `cancel()` | Non-throwing terminal cancellation | Cleanup failure is recorded; publication remains closed |

The unchanged non-throwing cancel contract records cleanup errors in failed state;
DEBUG builds also emit the existing cleanup diagnostic. No failed state can publish.
The public helper no longer conforms to `Sendable`: clients must give it one owner.
`ExportSession` remains `Sendable` and its asynchronous operation signatures are
unchanged. Count reads use the same Mutex-backed snapshot on supported targets;
there are no platform-specific synchronization branches in these modules.

## Verification and Change Impact

[ExporterLifecycleRegressionTests](../../Tests/CoreSpiceExporterTests/ExporterLifecycleRegressionTests.swift)
checks pre-start, mid-export and pre-publication cancellation, competing writers,
finalize/cancel ordering, complete bytes/counts and destination preservation.
Changing output ownership requires rechecking every format session and public
`ExportSession` conformance; the synchronous point-count getter remains available.
