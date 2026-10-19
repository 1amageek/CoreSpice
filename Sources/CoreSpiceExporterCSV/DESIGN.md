# CoreSpiceExporterCSV

## Purpose and Scope

Parent: [CoreSpice package](../../DESIGN.md). No children. Own the existing waveform
CSV export dialect and its reload behavior.

## Responsibilities and Boundaries

Serialize waveform descriptors and samples; parse that dialect back into waveform
values. Composition supplies physical variable meaning. This module does not
infer thermal physics, add ambient temperature or change numerical values.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Exporter composition | CSV module | No analysis qualification |
| [Exporter](../CoreSpiceExporter/DESIGN.md) | depends on | Output lifecycle | Atomic publication and cancellation | Preserve synchronous count snapshot |
| [Waveform](../CoreSpiceWaveform/DESIGN.md) | depends on | Descriptors, SI symbols, samples | Physical values | Preserve temperature rise and compiled column order |

## Architecture

```text
WaveformReadable -> CSVExporter -> names + optional unit suffixes + numeric rows
                              -> CSVWaveformReader -> WaveformData
```

## Contracts and Invariants

The unit suffix is a declared `SIUnit` symbol. `dT(...)` names identify temperature
rise columns, reloaded as `.temperature` with default `.kelvin` when no explicit
unit is present. Explicit units are preserved. `V(...)` and `I(...)` retain their
existing voltage/current interpretation. Numeric samples and column order remain
unchanged; unknown declared units and malformed CSV throw existing typed failures.
CSV lacks analysis metadata, so reload infers analysis from the sweep name and
canonical noise column names. Frequency sweeps containing an output or input
noise-density column reload as noise; other frequency sweeps reload as AC.
Canonical noise-density columns retain `.noiseDensity` and their explicit V²/Hz
or A²/Hz units; integrated output noise retains volts. Unitless noise-density
headers retain an unspecified unit because input quantity cannot be recovered
without the unit suffix. Complex real/imaginary partners must declare identical
optional units; a mismatch throws a typed error before waveform construction.
Numeric values, compiled column order and projection order survive reload.
Operating-point metadata and source-noise evidence require the separate JSON
record; CSV does not promise that metadata roundtrip.

## State, Ownership, and Lifecycle

Each CSV session is an actor. One non-suspending actor operation owns point
validation, first-header emission, row emission and count publication. Finalize
and cancel use that same authority. The shared output helper is owned exclusively
by the actor. The [shared export lifecycle](../CoreSpiceExporter/DESIGN.md#state-ownership-and-lifecycle)
is the authority for point-count snapshots, temporary output, cancellation and
atomic publication. No waveform callback or filesystem I/O runs under a Mutex.

Header fields containing the configured separator, a quote, CR or LF are always
quoted, irrespective of `quoteFields`; embedded quotes are doubled. The optional
flag forces quoting of other headers. The reader decodes those quoted logical
records, including doubled quotes and newlines inside a header name.

## Verification and Change Impact

[TemperatureRiseExportTests](../../Tests/CoreSpiceExporterTests/TemperatureRiseExportTests.swift)
verifies mixed V/A/K export and CSV reload, including a header without units.
Waveform descriptor/unit changes require checking this reader; existing exporter
tests own ordinary CSV formatting and failure behavior. RAW unit output is checked
by the same focused regression through the existing RAW exporter.
`DynamicWaveformExportTests` verifies complex V/A/K and transient CSV roundtrips,
reordered projections, both noise input units, descriptor JSON coding and broken
complex-pair units.
[ExporterLifecycleRegressionTests](../../Tests/CoreSpiceExporterTests/ExporterLifecycleRegressionTests.swift)
checks comma/quote/newline descriptors, forced and mandatory quoting, real and
complex sample roundtrips, custom separators and concurrent session operations.
