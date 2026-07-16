# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Design Philosophy

CoreSpice is a **production-grade SPICE simulator** targeting professional semiconductor and circuit design use cases. All implementation decisions must meet industry-standard SPICE requirements.

### Mandatory Rules

1. **No compromised designs.** Every device model, analysis algorithm, and numerical method must be implemented to the full specification of its reference standard (e.g., SPICE2G6, SPICE3F5, BSIM). Partial implementations that omit physically required parameters or behaviors are prohibited.
2. **Always verify completeness.** Before implementing or reviewing any feature, check against the complete parameter set and behavioral requirements of the relevant SPICE standard. Missing parameters, missing operating regions, or missing numerical safeguards must be identified and addressed — never silently omitted.
3. **Device models must be physically complete.**
   - MOSFET: All capacitance parameters (CGSO, CGDO, CGBO, CBD, CBS, CJ, CJSW, MJ, MJSW, PB, AD, AS, PD, PS), Meyer or charge-based gate capacitance model, junction capacitances with voltage dependence.
   - Diode/BJT: Junction capacitances, transit time, temperature effects.
   - Every `stampTransient` must include reactive (capacitive/inductive) behavior — not just repeat `stampDC`.
4. **Numerical methods must be robust.**
   - Newton-Raphson: Device-level voltage limiting (pnjlim for PN junctions, MOSFET terminal clamping).
   - LTE estimation: Variable-type normalization (`vntol` for voltages, `abstol` for currents).
   - Convergence aids: GMIN stepping and source stepping must be available in all analysis modes where NR is used.
5. **Accuracy is non-negotiable.** Companion models must maintain the theoretical convergence order of their integration method (e.g., trapezoidal = O(h²)). First-order approximations inside a second-order method are bugs, not simplifications.

## Build & Test Commands

```bash
swift build                                          # Build all targets
swift test                                           # Run all tests
swift test --filter CoreSpiceAnalysisTests           # Run one test module
swift test --filter CoreSpiceIRTests.NodeTests       # Run one test suite
swift test --filter CoreSpiceIRTests.groundNodeIsZero  # Run one test
```

Platform: macOS 26+, Swift 6.3. Uses Swift Testing framework (`@Suite`, `@Test`).

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

- **`Analysis`** (`CoreSpiceAnalysis`): Defines `run(plan:devices:solver:observer:cancellation:)`. Implementations: `DCAnalysis`, `ACAnalysis`, `TransientAnalysis`, `SweepAnalysis`, `TransferFunctionAnalysis`, `FourierAnalysis`, `SensitivityAnalysis`, `MonteCarloAnalysis`, `NoiseAnalysis`, `PoleZeroAnalysis`.
- **`DeviceDescriptor`** (`CoreSpiceDevices`): Declares device ports/parameters and produces a `BoundDevice` via `bind(instance:context:)`.
- **`BoundDevice`** (`CoreSpiceDevices`): Stamps device equations into the MNA matrix via `stampDC`, `stampAC`, `stampTransient`. Built-in: R, C, L, V/I sources, controlled sources, NMOS/PMOS Level 1.
- **`LinearSolver`** / **`ComplexLinearSolver`** (`CoreSpiceCompile`): LU factorization and solve for real/complex sparse systems.
- **`ComputeBackend`** / **`PhotonicComputeBackend`** (`CoreSpiceBackend`): GPU compute abstraction for Metal dispatch.
- **`CircuitCompiler`** (`CoreSpiceCompile`): Compiles `CircuitIR` into `ExecutionPlan` with matrix topology and sparsity structure.

### MNA Stamping Pattern

Every `BoundDevice` stamps into the Modified Nodal Analysis system through `MatrixStamper`. The stamper provides `stampConductance`, `stampVoltageSource`, `stampCurrentSource` helpers that map `Node`/`Branch` to matrix indices via `VariableMap`. The NR solver assembles `G * x = s` and solves directly (not correction form).

### Analysis Pipeline

1. **DC** (`.dc`): Newton-Raphson with Gmin stepping → source stepping fallback chain.
2. **AC** (`.ac`): DC operating point first, then complex frequency sweep `(G + jωC) * V = Is`.
3. **Transient** (`.tran`): DC for t=0, then adaptive timestep with Backward Euler → Trapezoidal, LTE-based step control.
4. **Transfer Function** (`.tf`): DC operating point → small-signal gain `V_out/V_in`, input impedance `Z_in`, output impedance `Z_out` via unit excitation.
5. **Fourier** (`.fourier`): Transient simulation → DFT at fundamental frequency. Extracts harmonic magnitudes, phases, and THD.
6. **Sensitivity** (`.sens`): Finite-difference perturbation of each device parameter. Runs N+1 DC solves (baseline + one per parameter). Reports absolute and normalized sensitivities.
7. **Monte Carlo** (`.mc`): Repeated inner analysis with random parameter variations (Gaussian/uniform). Supports deterministic seeding. Collects per-run results and statistics.
8. **Noise** (`.noise`): DC operating point → per-device noise contribution at each frequency → output-referred and input-referred spectral density. Integrated RMS noise over bandwidth.
9. **Pole-Zero** (`.pz`): DC operating point → extract G/C matrices from AC stamps → generalized eigenvalue problem (LAPACK QZ) for poles/zeros. DC gain from LAPACK `dgesv` dense solve of G matrix.

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

Uses Swift 6.3 strict concurrency: all public types are `Sendable`, shared mutable state uses `Mutex<T>` from `Synchronization`, event dispatch uses `DispatchQueue`. No `@unchecked Sendable`.

### Thread Safety in Tests

Swift Testing runs tests in parallel by default. Tests accessing shared resources must use a unified exclusion mechanism (actor or Mutex) across all suites.
