# Original Metric Evidence

## Purpose and Scope

Parent: [CLI](../DESIGN.md). No children. Owns host emission of domain semantics and current ToolQualification original metric definition links.

## Responsibilities and Boundaries

Owns original observation meaning and metric-definition publication; numerical units remain owned by Waveform/measurement producers.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CLI](../DESIGN.md) | parent | Actual completed phase and atomic publication | Host composition | Completion precedes emission |
| [Native](../../CoreSpice/NativeExecution/DESIGN.md) | depends on | Actual execution facts | Exact owner evidence | Prepared-only is not completed |
| [ToolQualification](../../../../ToolQualification/DESIGN.md) | used by | Original canonical schemas | Independent trust decision | Never issue qualification |

## Architecture

```text
completed domain facts -> host projection -> canonical artifacts -> atomic publication
```

## Contracts and Invariants

For every observed metric retain its waveform/measurement unit, stable extraction algorithm and domain semantic artifact. Generate and retain a canonical ToolQualificationMetricDefinition and bind the original execution schema3 metricDefinitionArtifacts to those exact artifacts. These are original observations/definitions, not comparisons or qualification. All serialization and publication respect existing byte/history/cancellation/atomic-rename budgets.

Declared header units are preserved as producer metadata, never inferred physical
units. Noise-density metadata from the completed typed NoiseResult declares V²/Hz or
A²/Hz according to the physical input quantity. The metric keeps that exact
declared PSD unit without rescaling. Older externally constructed dimensionless
noise metadata remains explicitly physical-unit-unavailable. Original metric
definitions do not confer physical qualification.

Pole-zero publication consumes the actual typed PoleZeroResult, not its dense
WaveformData presentation. Publish dc-gain plus each actual pole/zero real/imag
value under deterministic indexed identities. Empty pole/zero arrays create no
invented observations. The nonoptional typed dcGain is recorded only when present
in a successfully validated result; no missing gain is replaced by zero. Its
declared dimensionless unit and the typed result's documented rad/s frequency
unit are retained producer semantics, without numerical or SIUnit changes. Every
observation rejects nonfinite input. Padded NaN presentation slots are never
converted to observations, and genuinely nonfinite typed numerical construction
fails before publication. Existing history/encoded bounds apply to every value.

Sensitivity consumes Native's successful typed result and exact ordered fresh
completion ledger. Original selected baseline/child outputs form physical phases;
absolute and available normalized derivatives form an explicit derived phase.
A versioned CoreSpice artifact retains all frequencies, compensated DC/complex AC
observations, source-coordinate patches and effective increments. Metric domain
entries bind its opaque artifact reference; each derivative metric names its
baseline and matching child as contributors. Reload verifies the derivative from
the actual observations and refuses a mismatched source replacement. A missing
normalized value is explicit unavailable data, not a zero observation.

## State, Ownership, and Lifecycle

Immutable projection values; per-invocation phase collector owns synchronized history.
Publication owns staging files and removes partial output on failure/cancellation.
No device state or executable owner is reconstructed by decoding a receipt.

## Failure, Concurrency, and Constraints

Missing identity/meaning and byte/capacity violations fail explicitly. Existing
collector Mutex and publication owner keep the same isolation and cleanup contract.
No callbacks or I/O run under the collector lock.

## Verification and Change Impact

DiodeCLIAdmissionTests and affected case-output tests execute real adapters, decode
canonical artifacts and verify exact links; built CLI fixtures check success and
no-publication failures. Recheck native assumptions when preparation schema changes.

The collector's history, metric bindings and sensitivity artifact inventory share
one `Mutex<State>` on the host CLI target. Reads use snapshots, writes use the
same lock, and serialization/I/O occur after leaving it. There is no target
conditional storage or isolation replacement; CLI is a host adapter and is not
compiled as a WASM/Embedded target. Value artifacts retain their source-accounting
reservation; copying a value preserves the reservation owner until all copies end.
