# CoreSpiceExporterRAW

## Purpose and Scope

Parent: [CoreSpice package](../../DESIGN.md). No children. Own Berkeley RAW serialization.

## Responsibilities and Boundaries

Serialize real/complex waveform descriptors and samples. Numerical analysis and waveform storage remain caller-owned.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Export composition | Package entry point | No solver qualification |
| [Exporter](../CoreSpiceExporter/DESIGN.md) | depends on | Output lifecycle | Atomic export ownership | Preserve cancellation and point count |

## Architecture

```text
WaveformReadable -> session actor -> exclusive output helper -> partial file -> atomic publication
                               -> Mutex point-count snapshot
```

## Contracts and Invariants

One actor operation validates and writes a complete point, including the first
header, before publishing its point count. Finalize and cancel use the same actor.
RAW binary/ASCII rows follow a single header; ASCII indices equal the completed point count.

## State, Ownership, and Lifecycle

The session actor exclusively owns format state and the output helper. The
[shared export lifecycle](../CoreSpiceExporter/DESIGN.md#state-ownership-and-lifecycle)
is the authority for temporary output, count snapshots, cancellation, cleanup and
publication ordering. Every format operation is non-suspending inside the actor;
no row, header or trailer can interleave with another operation.

## Verification and Change Impact

[ExporterLifecycleRegressionTests](../../Tests/CoreSpiceExporterTests/ExporterLifecycleRegressionTests.swift)
checks pre-start, mid-export and pre-publication cancellation, competing writers,
finalize/cancel ordering, complete bytes/counts and destination preservation.
Changing output ownership requires rechecking every format session and public
`ExportSession` conformance; the synchronous point-count getter remains available.
