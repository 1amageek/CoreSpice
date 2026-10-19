# CoreSpiceWaveform

## Purpose and Scope

Parent: [CoreSpice package](../../DESIGN.md). No children. Own waveform values,
read-only views and numerical-result conversion for export and presentation.

## Responsibilities and Boundaries

Waveform samples and immutable metadata belong here. Native composition owns
resource policy and admission; Analysis owns numerical results. Conversions
transport an existing opaque Sendable storage lease and never reinterpret limits,
reserve the preparation envelope again or retain an obsolete numerical payload.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Waveform module composition | Exportable results | No physics qualification |
| [Analysis](../CoreSpiceAnalysis/DESIGN.md) | depends on | Result storage retention | Existing lease transport | Native limits remain opaque |
| [Native execution](../CoreSpice/NativeExecution/DESIGN.md) | coordinates with | Incremental capacity owner | Result lifetime | No duplicate byte charge |
| [IO](../CoreSpiceIO/DESIGN.md) | used by | Waveform output projection | Selected output values | Projection must preserve the lease |

## Architecture

```text
Analysis result + opaque lease -> WaveformData -> projection / borrowed view
                                 -> exporter / retained waveform copies
```

## Contracts and Invariants

Every supported numerical conversion retains only the result's opaque storage
owner. Waveform copies and views retain that same owner; IO output projection
transports it into the projected header. Final header release drops the lease.
Array/Dictionary extraction and unrelated materialization remain caller-owned
value boundaries. Unaccounted input waveforms have no lease. No new native
resource dependency, mutable shared state or target-specific ownership is added.

The validated MNA layout accepts an explicit `temperatureRiseNodes: Set<Node>`
from composition. Every supplied node must be a non-ground node-voltage unknown
in the exact compiled variable map. It changes only that row's descriptor to
`dT(name)`, `VariableType.temperature`, `SIUnit.kelvin`; values remain temperature
rises, without adding ambient temperature. All other descriptors retain their
existing electrical names and units. The layout retains the map and the checked
DC, AC and transient converters require exact map equality and solution width, preserving compiled
row indices. Invalid maps, thermal identities and dimensions throw typed failures.

```text
Compiled map + explicit thermal node identities -> validated variable layout
DC result + exact same map/layout -> shared COW numerical buffer + V/A/K descriptors
                                 -> CSV/RAW unit metadata and CSV reload
AC/transient + exact same map/layout -> complex/real solver rows + V/A/K descriptors
Noise result + input quantity -> output V²/Hz + input V²/Hz or A²/Hz + integrated V
```

`from(dcResult:variableLayout:title:)` stores the existing solution array directly
as one row-major point and transports the existing storage lease. It performs no
numeric reorder, intermediate numeric row creation or sample copy. The existing
topology-only conversion remains source-compatible and electrical by default.

The checked AC overload preserves every complex solver column in its original
order. Conversion materializes tuple rows at the existing complex waveform
storage boundary because Analysis owns `ComplexPair` rows. Transient conversion
retains the existing row-major COW buffer. A same-width layout with a different
MNA map is rejected for both. Noise PSD values are already validated by Analysis;
conversion preserves them without rescaling. `voltSquaredPerHertz` and
`ampereSquaredPerHertz` declare power spectral density, while integrated output
noise remains volts. Actual OP phases, accepted-step records and per-source noise
evidence remain owned by Analysis and Native/CLI results, not display waveforms.

### Transfer-function port projection

Transfer-function conversion emits one real point with `gain` first, then `Zin`
only for typed `inputPortImpedance.finite`, then `Zout` only for typed
`outputPortImpedance.finite`. Finite impedances retain their exact ohm values,
including zero and negative values. Typed `openCircuit` contributes no numeric
column; no infinity, NaN or substitute zero is emitted. Both ports are explicitly
classified in `SimulationMetadata.options` regardless of which columns exist:

| Key | Values |
|---|---|
| `input_port_impedance` | `finite` or `open_circuit` |
| `output_port_impedance` | `finite` or `open_circuit` |

These values come from Analysis `PortImpedance`, not numerical threshold tests or
missing-column inference. Finite results retain the existing `gain`, `Zin`,
`Zout` names and order; both-open results have only the actual gain. Conversion
retains the existing opaque storage owner. The typed Analysis result and CLI
transfer-function evidence remain the complete physical classification authority.
CSV preserves finite samples and units but does not encode arbitrary metadata
options, so missing CSV columns alone do not identify an open circuit.

```text
Typed finite/open input/output -> explicit metadata classification for both ports
                              -> gain + finite impedance columns -> finite persistence
```

### Pole-zero result projection

Pole-zero conversion emits one complex point at sweep `index = 0`. Its columns
are the actual poles in source-result order (`pole_0`, `pole_1`, ...), then the
actual zeros in their order (`zero_0`, `zero_1`, ...), then `dc_gain`. Every root
component is preserved in `radianPerSecond` (`rad/s`); gain is dimensionless with
its real value and zero imaginary component. Empty root lists contribute no
columns, so a result with no roots still emits its actual gain. The existing
opaque result storage owner is retained.

This replaces the former index-per-root layout and its shared `pole`/`zero`
columns. Consumers must use the individually named columns; no missing-root or
repeated-gain slots are synthesized. The waveform contains only finite values
already checked by the Analysis result and needs no NaN or zero padding. CSV
reads `rad/s` through the public SI unit raw-value contract; its existing analysis
kind/type inference remains distinct from the typed pole-zero result authority.

```text
Typed poles + zeros + gain -> one complex row: pole_0 ... zero_0 ... dc_gain
                           -> finite JSON samples / CSV with rad/s root units
```

### Sensitivity normalized availability

Sensitivity conversion preserves every absolute derivative and emits only finite
sample columns. DC retains the parameter-per-row layout and includes its shared
`normalized_sensitivity` column only when every parameter row defines that value.
AC retains a derivative column for every parameter and includes that parameter's
normalized column only when its entire frequency vector defines the value.
Fully defined results retain their existing column names, order and values.
Unavailable normalization is never replaced with zero, NaN or an availability
mask. The typed Analysis result and dedicated sensitivity evidence retain each
original optional normalized value; omitting a waveform column does not change
that authority or discard the absolute derivative rows.

```text
Typed sensitivity result -> all absolute derivative rows/columns
                         -> normalized columns with complete availability only
                         -> finite waveform -> strict sample persistence
```

## State, Ownership, and Lifecycle

The private lease field is initialized empty and assigned only on a new value
copy during conversion. Its Sendable owner protects mutable accounting through
the existing native Mutex. Samples remain existing immutable/COW storage. This
transport does not keep discarded numerical payload arrays alive.

## Verification and Change Impact

CoreSpiceNativeExecutionTests.NativeStorageAdmissionTests checks actual native
execution, conversion, SPICE selection, copy retention and final lease release.
Full Waveform/IO/CLI suites verify sample shape, projection and export behavior.
Changes to result ownership require rechecking native resource lifetime and the
ordinary and prepared CLI consumers. Native CPU evidence does not qualify GPU
or portable waveform execution.
Temperature-rise tests verify mixed V/A/K compiled row order, exact-map and width
refusal, explicit missing thermal identity refusal and shared numerical storage.
Exporter regression verifies Kelvin output and thermal descriptor preservation
across CSV reload; CSV descriptor inference is the consumer change boundary.
`DynamicWaveformConversionTests` checks exact-map/width refusals, complex mixed
V/A/K rows, shared transient storage and voltage/current input PSD units.
IO `SensitivityWaveformProjectionTests` checks zero-baseline DC, mixed DC
availability, an AC zero at one frequency, per-parameter AC availability,
complete-column compatibility, typed optional preservation, strict JSON sample
encoding and CSV save/reload.
`PoleZeroWaveformConversionTests` and the legacy `WaveformDataTests` conversion
case check unequal/empty root lists, complex order, gain-only output, dimensions
and storage-owner retention. IO `PoleZeroWaveformPersistenceTests` checks strict
JSON and actual CSV file save/readback of finite roots, gain and root units.
`TransferFunctionWaveformConversionTests` checks all finite/open port combinations,
compact indices, finite zero values, explicit classifications and opaque owner
retention. IO `TransferFunctionWaveformPersistenceTests` checks strict JSON file
readback including classification metadata and finite CSV sample/unit readback.

### Network presentation

Network parameter presentation has the distinct `network` analysis kind. It keeps
all finite S/Y row-major matrix entries as fixed named complex columns at every
frequency, with one-based response/excitation axes in column names and SI units.
The typed Analysis result remains the authority for port definitions, conditional
Z, stability availability and actual DC bias. Presentation never invents NaN or
zero values for unavailable quantities. Conversion retains the original result
storage owner and is admitted by the Native result scalar/materialization budget.
