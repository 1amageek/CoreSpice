# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                                          # Build all targets
swift test                                           # Run all tests
swift test --filter CoreSpiceAnalysisTests           # Run one test module
swift test --filter CoreSpiceIRTests.NodeTests       # Run one test suite
swift test --filter CoreSpiceIRTests.groundNodeIsZero  # Run one test
```

Platform: macOS 26+, Swift 6.2. Uses Swift Testing framework (`@Suite`, `@Test`).

## Module Dependency Graph

```
SharedTypes (C)    CoreSpiceEvent (no deps)    CoreSpiceParsedIR (no deps)
     │                    │                           │
     │              CoreSpiceIR ──────────────────────┤
     │              ╱          ╲                      │
     │    CoreSpiceDevices   CoreSpiceCompile    CoreSpiceParser
     │         │                  │                   │
     ├─── CoreSpiceBackend        │            CoreSpiceParserSPICE
     │         │                  │                   │
     │    CoreSpiceAnalysis ──────┘            CoreSpiceLowering
     │         │                                      │
     │         ├──────── CoreSpiceWaveform ───────────┤
     │         │              │                       │
     │    CoreSpice      CoreSpiceExporter            │
     │    (umbrella)          │                       │
     │                   ┌────┴────┬──────────┐       │
     │                   │         │          │       │
     │              ExporterRAW ExporterCSV ExporterPSF│
     │                   │         │          │       │
     │                   └────┬────┴──────────┘       │
     │                        │                       │
     │                   CoreSpiceIO (umbrella, re-exports all I/O)
     │
     └─── PluginsPhotonic (depends on IR, Devices, Compile, Backend, Event, SharedTypes)
```

## Architecture

CoreSpice is a SPICE circuit simulator with a photonic MZI mesh plugin. The simulation pipeline flows as:

**Netlist → CircuitIR → ExecutionPlan → Analysis → Result**

### Key Protocols

- **`Analysis`** (`CoreSpiceAnalysis`): Defines `run(plan:devices:solver:observer:cancellation:)`. Implementations: `DCAnalysis`, `ACAnalysis`, `TransientAnalysis`, `SweepAnalysis`.
- **`DeviceDescriptor`** (`CoreSpiceDevices`): Declares device ports/parameters and produces a `BoundDevice` via `bind(instance:context:)`.
- **`BoundDevice`** (`CoreSpiceDevices`): Stamps device equations into the MNA matrix via `stampDC`, `stampAC`, `stampTransient`. Built-in: R, C, L, V/I sources, controlled sources, NMOS/PMOS Level 1.
- **`LinearSolver`** / **`ComplexLinearSolver`** (`CoreSpiceCompile`): LU factorization and solve for real/complex sparse systems.
- **`ComputeBackend`** / **`PhotonicComputeBackend`** (`CoreSpiceBackend`): GPU compute abstraction for Metal dispatch.
- **`CircuitCompiler`** (`CoreSpiceCompile`): Compiles `CircuitIR` into `ExecutionPlan` with matrix topology and sparsity structure.

### MNA Stamping Pattern

Every `BoundDevice` stamps into the Modified Nodal Analysis system through `MatrixStamper`. The stamper provides `stampConductance`, `stampVoltageSource`, `stampCurrentSource` helpers that map `Node`/`Branch` to matrix indices via `VariableMap`. The NR solver assembles `G * x = s` and solves directly (not correction form).

### Analysis Pipeline

1. **DC**: Newton-Raphson with Gmin stepping → source stepping fallback chain.
2. **AC**: DC operating point first, then complex frequency sweep `(G + jωC) * V = Is`.
3. **Transient**: DC for t=0, then adaptive timestep with Backward Euler → Trapezoidal, LTE-based step control.

### SPICE I/O Architecture

The I/O system follows a compiler architecture pattern: **Frontend → IR → Backend**.

**Input Pipeline:**
```
SPICE Source → SPICEParser → ParsedNetlist → NetlistLowering → CircuitIR
```

- **`NetlistParser`** protocol (`CoreSpiceParser`): Defines `parse(source:fileName:)`. Implementation: `SPICEParser`.
- **`ParsedNetlist`** (`CoreSpiceParsedIR`): AST representation with components, models, subcircuits, analyses.
- **`NetlistLowering`** (`CoreSpiceLowering`): Evaluates expressions, expands subcircuits, resolves models → `CircuitIR`.

**Output Pipeline:**
```
AnalysisResult → WaveformData → WaveformExporter → File (.raw, .csv, .psf)
```

- **`WaveformData`** (`CoreSpiceWaveform`): Unified waveform IR with sweep values, variables, real/complex data.
- **`WaveformExporter`** protocol (`CoreSpiceExporter`): Defines `export(data:to:configuration:)`. Implementations: `RAWExporter`, `CSVExporter`, `PSFExporter`.
- **`ExportConfiguration`**: Variable filtering (wildcards), sweep range filtering, precision, compression.

**Key Types:**
- `ParsedExpression`: AST for parameter expressions (literals, identifiers, operators, functions).
- `VariableDescriptor`: Metadata for waveform variables (name, unit, type).
- `ParametricWaveformData`: Multi-run results with statistics (mean, stddev, percentiles).

### Photonic Plugin

`PluginsPhotonic` simulates 512-port MZI (Mach-Zehnder Interferometer) meshes. Layers alternate even/odd pairing patterns. `CoefficientGenerator` computes 2×2 unitary transfer matrices with phase factors. Metal kernels (`PhotonicKernels.metal`) apply layers on GPU. The `SharedTypes` C module defines `MZICoefficients` and `LayerDescriptor` structs shared between Swift and Metal.

### Concurrency

Uses Swift 6.2 strict concurrency: all public types are `Sendable`, shared mutable state uses `Mutex<T>` from `Synchronization`, event dispatch uses `DispatchQueue`. No `@unchecked Sendable`.

### Thread Safety in Tests

Swift Testing runs tests in parallel by default. Tests accessing shared resources must use a unified exclusion mechanism (actor or Mutex) across all suites.
