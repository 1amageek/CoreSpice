# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                                              # Build all targets
swift test --timeout 30                                  # Run all tests (always use timeout)
swift test --filter CoreSpiceAnalysisTests --timeout 30  # Run one test module
swift test --filter CoreSpiceIRTests.NodeTests --timeout 30  # Run one test suite
swift test --filter CoreSpiceIRTests.groundNodeIsZero --timeout 30  # Run one test
```

Platform: macOS 26+, Swift 6.2. Uses Swift Testing framework (`@Suite`, `@Test`).

## Module Dependency Graph

```
SharedTypes (C)    CoreSpiceEvent (no deps)
     │                    │
     │              CoreSpiceIR
     │              ╱          ╲
     │    CoreSpiceDevices   CoreSpiceCompile
     │         │                  │
     ├─── CoreSpiceBackend        │
     │         │                  │
     │    CoreSpiceAnalysis ──────┘
     │         │
     │    CoreSpice (umbrella, re-exports all)
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

### Photonic Plugin

`PluginsPhotonic` simulates 512-port MZI (Mach-Zehnder Interferometer) meshes. Layers alternate even/odd pairing patterns. `CoefficientGenerator` computes 2×2 unitary transfer matrices with phase factors. Metal kernels (`PhotonicKernels.metal`) apply layers on GPU. The `SharedTypes` C module defines `MZICoefficients` and `LayerDescriptor` structs shared between Swift and Metal.

### Concurrency

Uses Swift 6.2 strict concurrency: all public types are `Sendable`, shared mutable state uses `Mutex<T>` from `Synchronization`, event dispatch uses `DispatchQueue`. No `@unchecked Sendable`.

### Thread Safety in Tests

Swift Testing runs tests in parallel by default. Tests accessing shared resources must use a unified exclusion mechanism (actor or Mutex) across all suites.
