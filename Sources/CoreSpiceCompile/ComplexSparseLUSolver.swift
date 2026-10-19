/// Complete sparse LU factorization with numerical row pivoting for complex systems.
///
/// Structure and ordering are cached; numerical pivots and fill are recomputed
/// for each matrix. Storage follows input and factor nonzeros at every dimension.
public struct ComplexSparseLUSolver: ComplexLinearSolver {
    private var factorization = SparseLUFactorization<ComplexPair>()
    private var factorized = false

    /// Whether to use AMD ordering for fill reduction.
    public var useAMDOrdering: Bool = true

    /// Managed storage and work observed by the shared sparse factorization.
    public var statistics: SparseFactorizationStatistics { factorization.statistics }

    public init() {}

    /// Creates a solver with explicit fill-reducing ordering control.
    public init(useAMDOrdering: Bool) {
        self.useAMDOrdering = useAMDOrdering
    }

    /// Installs the caller's work, cancellation and storage admission policy.
    public mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {
        try factorization.configureExecution(control)
    }

    /// Factorizes a validated sparse matrix, invalidating previous factors on failure.
    public mutating func factorize(matrix: ComplexSparseMatrix) throws {
        factorized = false
        guard matrix.structuralMisses.isEmpty else {
            throw CompileError.incompatibleStructure(
                "Complex sparse matrix received stamps outside the CSR pattern: \(matrix.structuralMisses)"
            )
        }
        try factorization.factorize(
            structure: matrix.structure, values: matrix.values, useAMDOrdering: useAMDOrdering
        )
        factorized = true
    }

    /// Solves in original variable order, allocating the returned vector.
    public func solve(rhs: [ComplexPair]) throws -> [ComplexPair] {
        guard factorized else { throw CompileError.singularMatrix }
        return try factorization.solve(rhs: rhs)
    }

    /// Solves using the caller-owned result buffer as substitution workspace.
    public mutating func solve(rhs: [ComplexPair], into result: inout [ComplexPair]) throws {
        guard factorized else { throw CompileError.singularMatrix }
        try factorization.solve(rhs: rhs, into: &result)
    }
}
