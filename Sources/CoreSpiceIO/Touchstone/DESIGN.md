# Touchstone Network Exchange

## Purpose and Scope

Parent: [CoreSpiceIO](../DESIGN.md). No children. This component owns bounded
Touchstone syntax, imported network datasets and transactional encoded output.
It implements the single-ended network-exchange profile of the
[IBIS Touchstone 2.1 specification](https://ibis.org/touchstone_ver2.1/touchstone_ver2_1.pdf).
It does not own circuit analysis, RF conversion, stability or operating points.

## Responsibilities and Boundaries

`TouchstoneDecoding` and `TouchstoneEncoding` expose given-byte and given-dataset
operations. The decoder never discovers or opens an input file. Its incremental
value session owns incomplete lines, syntax state and bounded decoded points.
`TouchstoneData` contains one parameter kind, ordered reference resistances and
frequency/matrix points. It does not manufacture source or operating-point evidence.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [IO](../DESIGN.md) | parent | IO composition | Public codec placement | No waveform-name inference |
| [NetworkParameters](../../CoreSpiceAnalysis/NetworkParameters/DESIGN.md) | depends on | Immutable finite `NetworkParameterMatrix` | Row=response, column=excitation | No copied RF physics |
| [Exporter](../../CoreSpiceExporter/DESIGN.md) | coordinates with | `ExportDestination`, `ExportResult`, atomic publication semantics | Common output vocabulary | Its waveform-specific helper is not the network-data owner |

## Architecture

```text
given bytes -> incremental ASCII/line/token decoder -> TouchstoneData
                                                     -> NetworkParameterMatrix
typed network dataset -> bounded formatter -> exclusive output owner
                                           -> memory or partial file -> atomic publication
```

## Contracts and Invariants

| Boundary | Guarantee |
|---|---|
| Version profile | 2.0/2.1 single-ended S/Y/Z; legacy 1.x S requires explicit port count or `.sNp` extension hint. Legacy Y/Z, G/H, mixed-mode, noise, information blocks and unknown keywords fail explicitly |
| Values | Finite components, nonnegative strictly increasing Hz, positive finite per-port reference resistance; exact declared positive counts; no NaN/Inf, discarded points or zero padding |
| Representation | RI/MA/DB and Hz/kHz/MHz/GHz; v2 Y/Z are physical unnormalized values, references do not scale them |
| Ordering | Full, Lower, Upper and both two-port orders; triangular data reflects by transpose, not conjugation. Two-port triangular data is 11,21,22 for both triangles |
| Encoding | Default v2.1/Hz/RI/Full/12_21 supports exact binary64 value roundtrip. MA/DB are numerical conversions; DB cannot encode exact zero and refuses it. Triangular export requires exact symmetry |
| Unsupported input | Typed error with source name, byte offset, one-based physical line/column; no fallback to another representation |
| Limits | Caller-owned finite input/output bytes, line/token bytes, token count, ports, frequency points and retained storage; checked products and admission before buffer growth |

Options omitted as allowed by the standard use its defined defaults. Additional
option lines are ignored as explicitly specified, while unknown keywords and
unadopted semantic blocks are rejected. Comments are not semantic dataset fields.
The decoder checks every byte, including comments, for the specified ASCII set.
CR, LF and CRLF have stable physical positions across feed boundaries.
Option-line R values, Reference values and matrix values share the same finite
decimal/scientific numeric entrance; hexadecimal floating literals are refused.

## Runtime Flows

`TouchstoneStreamDecoder.append` consumes bounded chunks; `finish` checks terminal
syntax, exact counts and complete matrix pairs before returning a dataset.
No partial dataset is published on failure. The value session is single-owner
mutable state; copying it has ordinary value/COW semantics and no shared mutation.

`TouchstoneEncoder.encode` is a synchronous local memory operation for an existing
CLI staging transaction. `beginExport` creates an actor-owned session. Header,
point formatting, point count, finalize and cancel are serialized operations with
no suspension while state or I/O is in progress. The standalone file session owns
one same-directory temporary file; the CLI continues to own family naming and
multi-artifact atomic publication when it uses memory encoding.

## State, Ownership, and Lifecycle

```text
open -> write complete points -> finalize/count-check/close -> published
  |                                 |
  +-> cancellation or failure <------+
        -> close/remove only partial -> terminal
```

Cancellation is checked before creation, at bounded byte/token/point boundaries
and immediately before publication. A cancellation observed before publication
prevents success. Publication is the linearization point; later cancellation
does not revoke committed output. Explicit cancel/cleanup failures throw rather
than reporting successful cleanup. Owner destruction is best-effort cleanup;
callers complete `finalize` or `cancel` for checked resource release.

## Failure, Concurrency, and Constraints

The codec never executes callbacks or I/O under Mutex. Stream output uses an actor
with an exclusively owned non-Sendable synchronous writer. File writes are bounded
chunks; memory output is explicitly bounded by both output and retained limits.
Memory encoding uses a capacity-observable byte builder and admits its coexistence
with the one required `Data` materialization at the public output boundary.
The writer calls the output owner's shared prospective-row admission before
every row/header String append, accounting for existing memory-output capacity
and text/encoded-byte coexistence before the formatter grows.
Decoder storage admission counts retained matrices, point/reference buffers and
line/token scratch, including observed Array capacity. An error terminalizes its
session. Explicit limits are operational ceilings, not changes to network physics.

## Verification and Change Impact

[Touchstone tests](../../../Tests/CoreSpiceIOTests/Touchstone) own independent
matrix-order fixtures, S/Y/Z units/formats/references, legacy hints, triangular
symmetry, invalid/unsupported syntax and positions, incremental chunk boundaries,
overflow/resource refusal, exact RI roundtrip, checked output cleanup, competing
session calls, cancellation and preservation of an existing destination.
RF kernel tests own numerical conversion and stability. CLI tests own family
artifact naming, selected representation and whole-case publication.
