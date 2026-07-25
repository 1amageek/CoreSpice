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

    public static func analyze(structure: SparseStructure) -> SymbolicAnalysis
}

// Incremental parameter updates
public struct IncrementalUpdate: Sendable {
    public let modifiedDevices: Set<String>
    public let parameterChanges: [String: [String: Double]]
}
```

## Implementation Status

### Complete Features

| Feature | Status | Notes |
|---------|--------|-------|
| CSR sparse structure | Complete | Efficient deduplication and binary search lookup |
| Real sparse matrix | Complete | Value storage, accumulation, matrix-vector multiply |
| Complex sparse matrix | Complete | Full complex arithmetic support |
| LU decomposition (real) | Complete | Partial pivoting, forward/backward substitution |
| LU decomposition (complex) | Complete | Magnitude-based partial pivoting |
| Matrix topology mapping | Complete | MNA variable indexing, sparsity pattern generation |
| Execution plan generation | Complete | Standard compiler implementation |
| Incremental updates | Partial | Data structure defined, application logic in analysis module |

### Incomplete/Simplified Features

| Feature | Status | Notes |
|---------|--------|-------|
| Symbolic analysis | Simplified | Only ensures diagonal presence; does not predict off-diagonal fill-in |
| Sparse LU factorization | Dense conversion | Converts to dense internally; acceptable for small/medium circuits |

## Code Review Notes

### Strengths

1. **Clean Protocol-Oriented Design**: The `LinearSolver` and `ComplexLinearSolver` protocols allow for alternative solver implementations while providing a stable API.

2. **Value Types**: All types are structs with `Sendable` conformance, enabling safe concurrent use.

3. **Clear Separation of Concerns**: Structure (sparsity pattern) is separated from values, allowing pattern reuse across iterations.

4. **Comprehensive Documentation**: All public types and methods have doc comments with clear explanations.

5. **Structural Integrity**: Methods like `addValue` require positions to exist in the sparsity pattern and fail fast when a stamp targets a missing entry.

### Areas for Improvement

1. **Dense LU Factorization**: The `SparseLUSolver` and `ComplexSparseLUSolver` convert sparse matrices to dense arrays for factorization. This is O(n^2) in memory and O(n^3) in time. For large circuits (>1000 nodes), a true sparse LU algorithm (e.g., SuperLU, UMFPACK-style) would be significantly more efficient.

2. **Symbolic Analysis is Minimal**: The `SymbolicAnalysis.analyze` method only adds missing diagonal entries. A complete implementation would perform symbolic Gaussian elimination to predict all fill-in positions, which is important for:
   - Pre-allocating exact memory for factors
   - Optimal pivot ordering (AMD, COLAMD)
   - Reusing symbolic structure across Newton iterations

3. **Hardcoded Singularity Threshold**: Both solvers use `1e-15` as the singularity threshold. This should ideally be configurable or scaled relative to matrix norms for better numerical robustness.

4. **Sparse Input Validation**: Public `SparseStructure` construction validates
   dimensions, row-pointer shape and monotonicity, terminal nonzero count,
   column bounds, and per-row ordering. Internal compiler construction uses a
   checked-by-construction path.

5. **Error Type Reuse**: `solve(rhs:)` throws `CompileError.singularMatrix` when called without prior factorization. A more specific error (e.g., `.notFactorized`) would improve diagnostics.

6. **Branch Connectivity**: `MatrixTopology` uses each instance's owned and
   referenced branches to emit only local node/branch and branch/branch
   structure. A conservative fallback remains only for legacy programmatic IR
   whose branches have no instance association.

### Test Coverage

The test suite (`CoreSpiceCompileTests.swift`) covers:
- Sparse structure creation from triplets
- Sparse matrix operations (add, retrieve, clear, multiply)
- LU solver for 2x2 and 3x3 systems with pivoting
- Complex arithmetic and complex LU solver
- Matrix topology creation from circuit IR
- Standard compiler execution

### Quality Assessment

**Overall**: Good production-ready code for small to medium circuits. The implementation is correct, well-documented, and follows Swift best practices. For large-scale simulations, the dense LU approach would need to be replaced with a sparse direct solver.

**Maintainability**: High. Clear separation between files, consistent naming, and thorough documentation make the code easy to understand and modify.

**Performance**: Adequate for typical use cases. The O(n^3) LU factorization is the primary bottleneck for large circuits.
