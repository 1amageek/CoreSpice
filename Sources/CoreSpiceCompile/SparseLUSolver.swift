/// Pure Swift sparse CSC LU with complete numeric fill and partial row pivoting.
public struct SparseLUSolver: LinearSolver {
    public static let implementationIdentity = "CoreSpice.SparseLU.SwiftCSC.v2"
    public var useAMDOrdering = true
    private var kernel = SparseLUFactorization<Double>()
    private var factorized = false

    public init() {}
    public init(useAMDOrdering: Bool) { self.useAMDOrdering = useAMDOrdering }
    public var statistics: SparseFactorizationStatistics { kernel.statistics }
    public mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {
        try kernel.configureExecution(control)
    }
    public mutating func factorize(matrix: SparseMatrix) throws {
        factorized = false
        guard matrix.structuralMisses.isEmpty else {
            throw CompileError.incompatibleStructure("Sparse matrix received stamps outside the CSR pattern: \(matrix.structuralMisses)")
        }
        try kernel.factorize(structure: matrix.structure, values: matrix.values, useAMDOrdering: useAMDOrdering)
        factorized = true
    }
    public func solve(rhs: [Double]) throws -> [Double] {
        guard factorized else { throw CompileError.singularMatrix }
        return try kernel.solve(rhs: rhs)
    }
    public mutating func solve(rhs: [Double], into result: inout [Double]) throws {
        guard factorized else { throw CompileError.singularMatrix }
        try kernel.solve(rhs: rhs, into: &result)
    }
}
