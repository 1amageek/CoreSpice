# CoreSpiceParsedIR

## Purpose and Scope

This SwiftPM module owns parsed source values before domain admission. Its parent
is [CoreSpice](../../DESIGN.md); it has no child components.

## Responsibilities and Boundaries

Parsed values preserve source intent. Numeric source vectors retain their order;
parser syntax, scalar expression evaluation and device physics are separate owners.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Package composition | Parsed input boundary | Source preservation is not numerical admission |
| [ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md) | used by | Parsed values and resistor source roles | SPICE syntax preservation | Declaration acceptance is not numerical admission |
| [Lowering](../CoreSpiceLowering/DESIGN.md) | used by | Model references, separate parameter maps and expressions | Canonical IR translation | Scalar consumers reject vectors; runtime references remain expressions |

## Architecture

```mermaid
flowchart LR
  SPICE[Source syntax] --> Parsed[Parsed numeric vectors]
  Parsed --> Lowering[Canonical source parameters]
  Lowering --> Device[Strict waveform admission]
```

## Contracts and Invariants

### Captured model declaration origin

ParsedModel.origin currently retains the capture identity, actual declaration start
and parse-local ordinal. Repeated parses of one capture can repeat that declaration
identity; the bounded occurrence contract below closes this gap. Within one parse
it distinguishes declarations even when names match; it does not identify physical model parameters. Uncaptured/programmatic
models have nil origin. [IO](../CoreSpiceIO/DESIGN.md#consumed-source-capture-required-migration)
owns source bytes and capture policy. ParserSPICE creates origin from its actual
source document; lowering copies the selected identity without inferring it.


`numericVector` is a Sendable/Hashable ordered value. It is preserved by SPICE
serialization and lowering as `ParameterValue.realVector`; it never becomes a
scalar default. Source descriptors own finite, strictly increasing PWL admission.

### Resistor Source Provenance

`ParsedComponent.resistorModelCandidate` records only an ambiguous bare positional
identifier from resistor source syntax. Braced, quoted and named numeric values
never acquire this metadata, even when their expression is a single identifier.
Parser and scoped/include lowering resolve a candidate against visible model
declarations; its same-shaped numeric expression is never sufficient evidence
for reclassification. Unresolved candidates serialize as bare tokens and retain
the metadata through subcircuit node remapping. This source-only metadata never
enters model coefficients or physical instance parameter maps.

`ModelType.resistor` preserves source identity `R`. Declaration intake does
not by itself establish numerical execution. `ParsedModel` retains the
declaration name, type, original parameter values and location independently of
whether an instance uses it. `ParsedComponent.modelName` retains a source model
reference; its `parameters` retain only the placed instance's supplied values.
Neither map is replaced by a merged parameter dictionary at this boundary.

Static parameter expressions and simulation-voltage-dependent expressions share
the existing parsed expression representation. ParsedIR does not resolve names,
choose a runtime device, compute geometry resistance, assign a nominal
temperature, or decide noise capability. Those responsibilities belong to
[Lowering](../CoreSpiceLowering/DESIGN.md) and the
[Native Devices execution contract](../CoreSpiceDevices/Devices/DESIGN.md#resistor-execution-contract).
Unknown numerical parameters can remain losslessly represented in an unused
declaration; source preservation does not authorize ignoring them when used.

Verification must inspect both maps and the model reference after public parsing
and serialization, then follow public lowering to the existing canonical
`ResolvedDeviceModel`/`Instance.parameters` boundary. A model reference cannot
be erased by an explicit instance `r=`. No new parsed expression family or
foundry-qualified model type is introduced by the resistor declaration.

## Verification and Change Impact

[SPICEIOEndToEndTests](../../Tests/CoreSpiceIOTests/SPICEIOEndToEndTests.swift)
executes voltage/current PWL parsing, serialization, lowering, binding and actual
CPU transient output. Changes require parser, lowering and scalar consumer checks.

### Exact source dependency values

Status: implemented post-resolution exact-load integration. Grammar-owned
`SPICESourceDependencyEvent` values retaining parent/child capture IDs, original
physical SourceLocation, include versus external-library directive, selected
section, lexical occurrence ordinal and preprocessing context. Conditional event
evidence distinguishes active/inactive and unresolved selection. Capture IDs are
parse-local join keys, not canonical graph identity. ParsedIR remains independent
of PDK and host filesystem identity; consumers join events to their exact source
bindings. This is syntax evidence, not numerical model or qualification evidence.
[ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md) owns event production;
[IO](../CoreSpiceIO/DESIGN.md) owns checked capture/intake composition.


### Bounded source storage and occurrence values

Status: designed, not implemented. Existing work-count evidence does not
implement this portable boundary.

| Proposed public contract | Meaning |
|---|---|
| `SPICESourceResourceAccounting: SPICESourceWorkAccounting` | Requires `reserveStorage(kind:byteCount:) throws -> SPICESourceStorageReservation` and `chargeHashedBytes(_:) throws`; inherited work/check requirements stay synchronous and Sendable |
| `SPICESourceStorageKind` | `liveOwnedBytes` and `temporaryBytes`: managed logical extent, not process RSS |
| `SPICESourceStorageReservation` | Immutable shared release owner with public trusted-accountant initializer `(kind:byteCount:release:)`; final-copy destruction releases once, also after admission closes; no Codable or source/result authority |
| `SPICEParseOccurrenceID` | Opaque invocation-local identity allocated before parsing; distinct from source/content keys and diagnostic paths |
| `SPICEOwnedParseResult` | Internally checked successful netlist with immutable source/derived-storage reservations; copies share retained owners |

A trusted external accountant may construct a reservation from its admitted kind/
byte count and a `@Sendable () -> Void` release callback, retaining its original
accounting token in that callback owner. All value copies share one immutable
release owner; callback executes exactly once outside accountant locks. This is
an accounting/lifetime receipt, not checked source or parse-result authority.

Managed extents are reserved UTF-8 byte capacities, collection slot capacities
multiplied by the checked stride of their stored element type, map/set entry
payload capacities, and concrete associated payloads of expression nodes.
Separately allocated strings/child containers are charged separately. Inline
references do not charge shared child payload twice. Compiler/allocator headers,
allocator slack, hash-table buckets and RSS are outside this logical metric.
Token counts and guessed input multipliers are never byte leases.

Reserve before materialization, growth, transform or COW clone. Shared immutable
backing retains one lease; mutation of shared backing admits its concrete logical
capacity before copying. Both buffers remain charged during migration; refund
obsolete scratch when its owner ends. A private immutable identity marker may
track collection write uniqueness. Rejection leaves the previous snapshot intact.
Reservation-array metadata has its concrete capacity cost; accountant-internal
allocation is outside parser-managed storage. No slab, arena or new allocator is
required merely to meter existing values.

The owned result keeps netlist and leases together. Extraction of raw ParsedNetlist
or diagnostic payload is an explicit caller-owned boundary: bounded callers retain
the owner through that use. The PDK adapter deep-copies exported facts under its
accountant before releasing the lower result. Input-derived failures retain only
immutable owners needed by their payload; static resource/cancellation failures do
not retain an entire parse. No partial netlist authenticates successful facts.

Bounded dependency/model/subcircuit origins carry occurrence IDs alongside
content join keys. Dependency records retain original physical UTF-8 statement
offset, source-local statement ordinal, actual child section and child-entry
identity. Merged lexical order stays depth first. Repeated content reuse never
collapses edges or origins. Occurrence IDs/paths are not canonical profile identity.

Verification owner: focused source-resource tests in
[ParsedIRTests](../../Tests/CoreSpiceParsedIRTests/) and actual bounded grammar
proof in [ParserSPICE](../CoreSpiceParserSPICE/DESIGN.md). Prove overflow/refusal
before allocation, final-copy release, same-capacity COW clone, migration overlap
and repeated-content origin distinction. Native proof does not establish
WASM/Embedded allocator or synchronization behavior.
