/// A solver for real-valued sparse linear systems.
///
/// Implementations first factorize a matrix and then solve for
/// one or more right-hand-side vectors using the stored factorization.
public protocol LinearSolver: Sendable {

    /// Factorizes the given matrix.
    ///
    /// After a successful call the solver is ready to accept
    /// calls to ``solve(rhs:)``.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if the matrix is singular.
    mutating func factorize(matrix: SparseMatrix) throws

    /// Solves `A * x = rhs` using the stored factorization.
    ///
    /// ``factorize(matrix:)`` must have been called before this method.
    ///
    /// - Parameter rhs: Right-hand-side vector of length equal to the matrix dimension.
    /// - Returns: The solution vector `x`.
    func solve(rhs: [Double]) throws -> [Double]
}

/// A solver for complex-valued sparse linear systems.
public protocol ComplexLinearSolver: Sendable {

    /// Factorizes the given complex matrix.
    mutating func factorize(matrix: ComplexSparseMatrix) throws

    /// Solves `A * x = rhs` using the stored factorization.
    func solve(rhs: [ComplexPair]) throws -> [ComplexPair]
}
