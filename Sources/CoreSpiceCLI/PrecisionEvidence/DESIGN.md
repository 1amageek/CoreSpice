# Precision Evidence

## Purpose and Scope

Parent: [CoreSpiceCLI](../DESIGN.md). No children. Own bounded precision inspection
values and the typed CSV companion for canonical paired transient coordinates.
Full JSON remains the authority for names, units, configuration, model receipts
and accepted-step audit. The parent owns source-command and Native composition.

## Responsibilities and Boundaries

`CoreSpiceCLIPairedCSVRecord` owns immutable validated component values and an
explicit compiled-row subset/order. `CoreSpiceCLIPairedCSVCodec` serializes and
checks the numeric wire format. CLI composition owns selection, file I/O and
cross-checking the decoded companion against full JSON. Ordinary CSV, waveform
types, model evaluation and display transforms remain outside this component.

`CoreSpiceCLIPrecisionExecution` composes immutable source/settings/cold snapshot
values, admitted component bits and accepted-step audit. Its configuration adapter
converts those values to the Native verifier's public facts; Native owns the
commitment algorithm. The parent [precision composition contract](../DESIGN.md#s4-precision-transient-cli-composition)
defines the versioned complete record and its integration. Program/source binary
fields use bounded canonical base64 and exact content checks. These inspection
values carry no executable model, worker process or resume authority.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CLI](../DESIGN.md) | parent | Completed evidence and artifact composition | Integrates companion files | No completion inferred from encoding |
| [Numerical state](../../CoreSpiceDevices/NumericalState/DESIGN.md) | depends on | Finite normalized component pair | Validate high/low without collapsing | Preserve original component bits, including signed zero |
| [CSV exporter](../../CoreSpiceExporterCSV/DESIGN.md) | coordinates with | Existing ordinary display CSV | Separate unchanged presentation | Its 15-digit default cannot carry paired proof |

## Architecture

```text
full canonical paired JSON trace + configuration digest + explicit compiled rows
  -> validated immutable paired CSV record
  -> bounded numeric CSV encoding -> CLI file save/read
  -> strict bounded decode -> exact component-bit and row/time cross-check to JSON
```

## Contracts and Invariants

The format starts with six fields: `corespice-paired-csv`, version `1`, the
lowercase 64-character configuration SHA-256, full point count, canonical source
row count and selected row count. The next record is `compiled_rows` followed by
the selected distinct canonical row indices in their requested order. The third
record is the fixed header:

```text
point_index,time,time_bits,column_index,compiled_row,high,high_bits,low,low_bits
```

Every subsequent record has nine numeric fields. Records occur in point-major
order, with all selected columns for each complete point. Point and column
indices must exactly match that order; compiled rows must match the preamble.
Times repeat with identical bits within a point. Times are finite, nonnegative
and strictly increase between points. Values and their decimal UInt64 bit
patterns must agree. High/low components must be finite and normalized; absence
is failure. Encoding uses `String(Double)` and original component bit patterns,
preserving sub-ULP values and signed zero. Decoding validates a pair without
replacing the original components with a newly normalized value.

Field names are system-controlled. This restricted numeric format has no quoted
fields, arbitrary names or units. Each field is at most 64 UTF-8 bytes. Integer
fields use decimal digits. LF and CRLF records are accepted; blank, extra,
truncated, reordered or duplicate records fail explicitly. Version mismatch,
malformed UTF-8, digest, geometry, bits and pairs have typed errors.

An explicit row subset/reorder changes only the companion's canonical row map.
The default supplied by CLI is the complete canonical row set. Display-derived
signals such as differences, magnitude or phase never supply reconstructed lows:
the canonical paired companion remains independent of that ordinary display CSV.
Names/units and exact accepted-step/model evidence are read from the full JSON
using the shared configuration digest and canonical row indices.

## State, Ownership, and Lifecycle

The record uses immutable COW arrays; a complete trace can share its existing
buffers. Subset materialization belongs to the explicit artifact boundary.
Encoding/decoding has call-local buffers only. No mutable shared state, process,
callback, platform condition or alternate synchronization contract is added.

## Failure, Concurrency, and Constraints

Caller limits explicitly bound bytes, point count, canonical/selected column
counts and total stored Double scalars (`points + 2*points*selectedColumns`).
Products and sums are checked before allocation. Encoding admits a conservative
minimum byte geometry before constructing records and checks actual bytes before
each append. The potentially large row-map record has its exact decimal digit,
separator and newline byte count admitted before constructing its field strings
or joined line. Decoding checks the byte limit before UTF-8 conversion, validates
declared geometry before reserving numerical arrays and parses one bounded-field
record at a time. The declared minimum record bytes must also fit the actual
input bytes before reservations. It does not first split an untrusted file into a line/field
matrix. Record boundaries use the LF UTF-8 code unit, preserving CRLF support
when Swift treats that sequence as one grapheme. Pure parsing work is linear in bounded input bytes and scalar count.
Any failure returns no decoded record or partial encoded result. CLI owns atomic
publication and its existing resource admission for file/artifact copies.

## Verification and Change Impact

[PairedCSVCodecTests](../../../Tests/CoreSpiceCLITests/PairedCSVCodecTests.swift)
owns complete/subset/reordered roundtrips, signed-zero and sub-ULP component bits,
schema/count/map/time/value/pair failures, duplicates/order/truncation and limits.
CLI integration must save/read/decode then compare every original component bit,
time, configuration digest and compiled row against its full JSON record.
Changing this schema requires corresponding strict reader and CLI integration
updates. Ordinary CSV defaults and waveform APIs remain unaffected.
