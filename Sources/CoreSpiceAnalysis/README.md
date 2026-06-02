# CoreSpiceAnalysis

A Swift module providing circuit analysis engines for SPICE-like electrical circuit simulation. This module implements DC operating point, AC small-signal, and transient time-domain analyses using Modified Nodal Analysis (MNA) and Newton-Raphson iteration.

## Overview

CoreSpiceAnalysis is the computational core of the CoreSpice circuit simulator. It provides:

- **DC Analysis**: Finds the steady-state operating point of a circuit
- **AC Analysis**: Performs frequency-domain small-signal analysis
- **Transient Analysis**: Simulates time-domain behavior with adaptive timestep control
- **Parametric Sweep**: Runs any analysis across a range of parameter values

The module uses protocol-oriented design with the `Analysis` protocol as the primary abstraction, allowing all analysis types to share a common execution interface while remaining type-safe.

## File List

### Core Protocol and Errors

| File | Description |
|------|-------------|
| `AnalysisProtocol.swift` | Defines the `Analysis` protocol with associated `Result` type and async `run()` method |
| `AnalysisError.swift` | Error enum for convergence failures, singular matrices, cancellation, and timestep issues |

### DC Analysis

| File | Description |
|------|-------------|
| `DCAnalysis.swift` | DC operating point analysis with convergence aids (Gmin stepping, source stepping) |
| `DCResult.swift` | Result container with converged solution vector and accessors for voltage/current |
| `DCEvent.swift` | Event types for DC analysis progress reporting |
| `GminStepping.swift` | Convergence aid that progressively reduces minimum conductance |
| `SourceStepping.swift` | Convergence aid that ramps sources from zero to full value |

### AC Analysis

| File | Description |
|------|-------------|
| `ACAnalysis.swift` | AC small-signal frequency-domain analysis (DC op point + frequency sweep) |
| `ACResult.swift` | Result container with complex solution vectors and dB/phase accessors |
| `ACEvent.swift` | Event types for AC analysis progress reporting |
| `FrequencySweep.swift` | Frequency sweep specification (decade, linear, or single point) |

### Transient Analysis

| File | Description |
|------|-------------|
| `TransientAnalysis.swift` | Time-domain analysis with adaptive timestep and LTE control |
| `TransientResult.swift` | Result container with time points and solution trajectory |
| `TransientEvent.swift` | Event types for transient analysis progress reporting |
| `TransientConfig.swift` | Configuration for stop time, timestep limits, LTE tolerance, etc. |
| `BreakpointManager.swift` | Manages waveform discontinuity breakpoints for timestep control |
| `LTEEstimator.swift` | Local Truncation Error estimator for adaptive timestep control |

### Parametric Sweep

| File | Description |
|------|-------------|
| `SweepAnalysis.swift` | Generic parametric sweep wrapper for any inner analysis |
| `SweepResult.swift` | Generic result container for sweep results |
| `SweepEvent.swift` | Event types for sweep progress reporting |

### Solver Infrastructure

| File | Description |
|------|-------------|
| `NewtonRaphsonSolver.swift` | Reusable Newton-Raphson nonlinear iteration engine |
| `ConvergenceConfig.swift` | Configuration for Newton-Raphson tolerances (abstol, reltol, vntol, gmin) |

## Public API Summary

### Analysis Protocol

```swift
public protocol Analysis: Sendable {
    associatedtype Result: Sendable

    func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> Result
}
```

### DCAnalysis

```swift
public struct DCAnalysis: Analysis {
    public typealias Result = DCResult

    public init(
        config: ConvergenceConfig = ConvergenceConfig(),
        gminStepping: GminStepping = GminStepping(),
        sourceStepping: SourceStepping = SourceStepping()
    )
}
```

### ACAnalysis

```swift
public struct ACAnalysis: Analysis {
    public typealias Result = ACResult

    public init(
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    )
}
```

### TransientAnalysis

```swift
public struct TransientAnalysis: Analysis {
    public typealias Result = TransientResult

    public init(
        config: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig()
    )
}
```

### SweepAnalysis

```swift
public struct SweepAnalysis<A: Analysis>: Sendable {
    public init(
        parameterName: String,
        values: [Double],
        analysisFactory: @Sendable @escaping (Double) -> A
    )

    public func run(...) async throws -> SweepResult<A.Result>
}
```

### Configuration Types

```swift
public struct ConvergenceConfig: Sendable {
    public var abstol: Double      // Default: 1e-12
    public var reltol: Double      // Default: 1e-3
    public var vntol: Double       // Default: 1e-6
    public var maxIterations: Int  // Default: 50
    public var gmin: Double        // Default: 1e-12
}

public struct TransientConfig: Sendable {
    public var stopTime: Double
    public var maxTimeStep: Double
    public var initialTimeStep: Double?
    public var minTimeStep: Double           // Default: 1e-18
    public var initialMethod: IntegrationMethod  // Default: .backwardEuler
    public var lteTolerance: Double          // Default: 1e-4
    public var maxTimeStepReductions: Int    // Default: 10
    public var shrinkFactor: Double          // Default: 0.5
}

public enum FrequencySweep: Sendable {
    case decade(start: Double, stop: Double, pointsPerDecade: Int)
    case linear(start: Double, stop: Double, points: Int)
    case single(Double)
}
```

### Result Types

```swift
public struct DCResult: Sendable {
    public let variables: [Double]
    public let variableMap: [MNAVariable: Int]
    public let iterations: Int

    public func voltage(at node: Node) -> Double
    public func current(through branch: Branch) -> Double
}

public struct ACResult: Sendable {
    public let frequencies: [Double]
    public let solutions: [[ComplexPair]]
    public let variableMap: [MNAVariable: Int]

    public func voltage(at node: Node, frequencyIndex: Int) -> ComplexPair
    public func magnitudeDB(at node: Node, frequencyIndex: Int) -> Double
    public func phase(at node: Node, frequencyIndex: Int) -> Double
}

public struct TransientResult: Sendable {
    public let timePoints: [Double]
    public let solutionTrace: SolutionTrace
    public let variableMap: [MNAVariable: Int]
    public let timeSteps: Int
    public let rejectedSteps: Int

    public func voltage(at node: Node, timeIndex: Int) -> Double
    public func value(variableIndex: Int, timeIndex: Int) -> Double
    public func withSolution<R>(at timeIndex: Int, _ body: (UnsafeBufferPointer<Double>) throws -> R) rethrows -> R
    public func voltageWaveform(at node: Node) -> [(time: Double, value: Double)]
}
```

`solutionTrace` is the canonical transient storage. Nested `[[Double]]`
transient storage is intentionally not part of `TransientResult`; any row
materialization must be an explicit boundary operation outside the computation
hot path.

## Implementation Status

### Complete Features

- [x] DC operating point analysis with Newton-Raphson iteration
- [x] Gmin stepping convergence aid
- [x] Source stepping convergence aid
- [x] AC small-signal analysis with frequency sweep
- [x] Transient analysis with adaptive timestep control
- [x] Local Truncation Error (LTE) estimation for Backward Euler and Trapezoidal
- [x] Breakpoint management for waveform discontinuities
- [x] Convergence checking with SPICE-standard tolerances
- [x] Event dispatching for progress monitoring
- [x] Cooperative cancellation support
- [x] Generic parametric sweep analysis

### Incomplete/Partial Features

- [ ] **Integration Method**: Only Backward Euler and Trapezoidal methods are supported. Higher-order methods (Gear) are not implemented.

## Code Review Notes

### Design Patterns

1. **Protocol-Oriented Design**: The `Analysis` protocol with associated types provides clean type-safe abstraction.

2. **Value Types**: All analysis types, configurations, and results are `struct` types conforming to `Sendable`, enabling safe concurrent usage.

3. **Dependency Injection**: Analyses receive their dependencies (`solver`, `observer`, `cancellation`) through the `run()` method, making them testable.

4. **Event-Driven Observability**: The `EventDispatcher` integration provides comprehensive progress and diagnostic events.

5. **Caller-Owned Buffers**: Transient and Newton-Raphson hot paths reuse caller-owned solution buffers and row-major trace storage to avoid nested-array churn.

### Code Quality Assessment

**Strengths:**

- Clean separation of concerns with one type per file
- Comprehensive documentation with doc comments
- Standard SPICE convergence parameters and algorithms
- Proper error handling with typed errors
- Good use of Swift concurrency (async/await, Sendable)

**Open Follow-ups:**

1. **Missing Error Handling for Complex Solver** (`ACAnalysis.swift`, lines 137-138):
   The `factorize()` and `solve()` calls throw but do not wrap errors in `AnalysisError` types like the DC analysis does.

2. **Potential Precision Issue** (`BreakpointManager.swift`, line 27):
   Near-duplicate detection uses `1e-15` which may be too tight for typical simulation time scales. Consider making this configurable or relative to the time values.

### Dependencies

This module depends on:
- `CoreSpiceCompile` - ExecutionPlan, SparseMatrix, LinearSolver, MatrixStamper
- `CoreSpiceDevices` - BoundDevice, IntegrationMethod, IntegrationState, SolutionState
- `CoreSpiceIR` - Node, Branch, MNAVariable
- `CoreSpiceEvent` - EventDispatcher, AnalysisID, various Info types
- `Foundation` - Basic math functions

### Recommendations

1. Add error wrapping for complex solver failures in `ACAnalysis`.

2. Consider implementing Gear integration methods for improved accuracy in stiff circuits.
