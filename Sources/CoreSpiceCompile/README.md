# CoreSpiceCompile Module

## Overview

CoreSpiceCompile is the circuit compilation module for CoreSpice, a SPICE-like circuit simulator written in Swift. This module transforms circuit intermediate representations (from CoreSpiceIR) into execution plans suitable for numerical analysis. It provides:

- **Sparse Matrix Infrastructure**: CSR (Compressed Sparse Row) format storage for efficient memory usage and matrix operations
- **Linear System Solvers**: LU decomposition with partial pivoting for both real and complex-valued systems
- **Matrix Topology Mapping**: Translation from circuit connectivity to MNA (Modified Nodal Analysis) matrix structure
- **Symbolic Analysis**: Prediction of fill-in during matrix factorization
- **Execution Planning**: Packaging of compiled circuit data for analysis engines

## Dependencies

- `CoreSpiceIR`: Provides circuit IR types (`CircuitIR`, `Node`, `Branch`, `Instance`, `MNAVariable`, `CircuitTopology`)

## File List

| File | Description |
|------|-------------|
| `CompileError.swift` | Error types for compilation failures |
| `SparseStructure.swift` | CSR sparsity pattern (structural positions only) |
| `SparseMatrix.swift` | Real-valued sparse matrix with CSR storage |
| `ComplexSparseMatrix.swift` | Complex-valued sparse matrix and `ComplexPair` type |
| `LinearSolver.swift` | Protocols for real and complex linear solvers |
| `SparseLUSolver.swift` | LU decomposition solver for real matrices |
| `ComplexSparseLUSolver.swift` | LU decomposition solver for complex matrices |
| `SymbolicAnalysis.swift` | Symbolic factorization analysis for fill-in prediction |
| `MatrixTopology.swift` | Maps circuit topology to MNA matrix indices |
| `ExecutionPlan.swift` | Container for compiled circuit execution data |
| `IncrementalUpdate.swift` | Describes partial parameter updates for re-stamping |
| `CircuitCompiler.swift` | `CircuitCompiler` protocol and `StandardCompiler` implementation |

## Public API Summary

### Error Handling

```swift
public enum CompileError: Error, Sendable {
    case unknownDeviceType(String)
    case bindingFailed(instance: String, reason: String)
    case emptyCircuit
    case singularMatrix
    case incompatibleStructure(String)
}
```

### Sparse Matrix Types

```swift
// Sparsity pattern (structural positions)
public struct SparseStructure: Sendable {
    public let dimension: Int
    public let rowPointers: [Int]
    public let columnIndices: [Int]
    public var nonZeroCount: Int { get }

    public init(dimension: Int, rowPointers: [Int], columnIndices: [Int])
    public static func fromTriplets(
        dimension: Int,
        entries: [(row: Int, col: Int)]
    ) throws -> SparseStructure
    public func index(row: Int, col: Int) -> Int?
}

// Real-valued sparse matrix
public struct SparseMatrix: Sendable {
    public let structure: SparseStructure
    public private(set) var values: [Double]
    public var dimension: Int { get }

    public init(structure: SparseStructure)
    public mutating func clear()
    public mutating func addValue(row: Int, col: Int, value: Double)
    public func value(row: Int, col: Int) -> Double
    public func multiply(vector: [Double]) throws -> [Double]
}

// Complex number type
public struct ComplexPair: Sendable, Hashable {
    public var real: Double
    public var imag: Double
    public var magnitude: Double { get }
    public var conjugate: ComplexPair { get }
    public static let zero: ComplexPair
    public static let one: ComplexPair
    // Arithmetic operators: +, -, *, /
}

// Complex-valued sparse matrix
public struct ComplexSparseMatrix: Sendable {
    // Same API as SparseMatrix but with ComplexPair values
}
```

### Linear Solvers

```swift
// Protocol for real solvers
public protocol LinearSolver: Sendable {
    mutating func factorize(matrix: SparseMatrix) throws
    func solve(rhs: [Double]) throws -> [Double]
}

// Protocol for complex solvers
public protocol ComplexLinearSolver: Sendable {
    mutating func factorize(matrix: ComplexSparseMatrix) throws
    func solve(rhs: [ComplexPair]) throws -> [ComplexPair]
}

// Concrete implementations
public struct SparseLUSolver: LinearSolver
public struct ComplexSparseLUSolver: ComplexLinearSolver
```

### Topology and Compilation

```swift
// Matrix topology mapping
public struct MatrixTopology: Sendable {
    public let dimension: Int
    public let variableMap: [MNAVariable: Int]
    public let structure: SparseStructure
    public let circuitTopology: CircuitTopology

    public init(ir: CircuitIR)
    public func variableIndex(for variable: MNAVariable) -> Int?
    public func nodeIndex(_ node: Node) -> Int?
}

// Execution plan (compiled output)
public struct ExecutionPlan: Sendable {
    public let ir: CircuitIR
    public let topology: MatrixTopology
    public let matrixStructure: SparseStructure
    public let deviceNames: [String]
}

// Compiler protocol and implementation
public protocol CircuitCompiler: Sendable {
    func compile(ir: CircuitIR) throws -> ExecutionPlan
}

public struct StandardCompiler: CircuitCompiler
```

### Utility Types

```swift
// Symbolic analysis for fill-in prediction
public struct SymbolicAnalysis: Sendable {
    public let fillInCount: Int
    public let factorizationStructure: SparseStructure

    public static func analyze(structure: SparseStructure) throws -> SymbolicAnalysis
}

// Incremental parameter updates
public struct IncrementalUpdate: Sendable {
    public let modifiedDevices: Set<String>
    public let parameterChanges: [String: [String: Double]]
}
```

## Numerical and Resource Contracts

The real and complex solvers use a shared Pure Swift column-oriented sparse LU.
Updated Schur-column values select numeric row pivots. All nonzero computed fill
is retained; no fixed absolute singularity/drop threshold or dense fallback is
used. Input CSR and the selected ordering key reusable structural preparation.
Numerical pivots and fill are recomputed for every matrix value update.

Storage follows dimension, input entries and actual factor fill, including managed
capacity slack. Sparse inputs can still produce dense factors. The indexed
minimum-degree heap removes the former dimension scan per eliminated node; its
explicit clique fill is still genuine work/storage that may require refusal.
SymbolicAnalysis is an advisory no-numeric-pivot view and is not a factor-capacity
certificate. Ordering and symbolic APIs propagate control failures with throws.

Bounded callers install LinearSolverExecutionControlling through the solver
protocol requirement. Work/checkpoint and capacity leases join the existing run
budget; a custom solver that cannot enforce a nonnil controller refuses explicitly.
Unbounded low-level calls remain available and do not claim application ceilings.
The inout solve uses caller-owned result storage; the allocating variant allocates
its returned vector. Repeated same-structure factorization can reuse numeric buffer
capacity. Copy-on-write and replacement capacity are admitted before mutation.

See [factorization](SparseFactorization/DESIGN.md), [ordering](SparseOrdering/DESIGN.md)
and [Analysis composition](../CoreSpiceAnalysis/SparseExecution/DESIGN.md) for the
normative numerical, ownership, failure and verification contracts. Native solver
identity is CoreSpice.SparseLU.SwiftCSC.v2; previous evidence is not silently relabeled.

## Verification Scope

Compile tests cover independent dense-reference solutions, updated Schur pivots,
nonsymmetric fill, extreme scales, cache/ordering changes, multiple right-hand
sides, invalid values/shapes, failed-factor refusal, capacity/work/cancellation,
solver-copy ownership and sparse diagonal/band scaling. Original CSR residuals
remain the numerical check; factor structure alone does not establish accuracy.

Large extracted PEX accuracy, cold-process peak RSS and time, Native API/CLI
persistence and repeated-factor measurements are qualified separately by
[the package tooling](../../tools/SparseQualification/DESIGN.md). Implementation
and focused test success alone do not establish foundry or whole-platform
production readiness, general sparse-memory complexity under arbitrary fill,
end-to-end acceleration, or zero-copy behavior.
