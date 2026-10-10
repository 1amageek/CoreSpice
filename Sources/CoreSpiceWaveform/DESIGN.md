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
