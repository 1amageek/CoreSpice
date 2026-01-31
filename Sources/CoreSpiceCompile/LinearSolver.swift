/// A solver for real-valued sparse linear systems.
///
/// Implementations first factorize a matrix and then solve for
/// one or more right-hand-side vectors using the stored factorization.
public protocol LinearSolver: Sendable {

    /// Factorizes the given matrix.
    ///
    /// After a successful call the solver is ready to accept
    /// calls to ``solve(rhs:)`` or ``solve(rhs:into:)``.
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

    /// Solves `A * x = rhs` using the stored factorization, writing
    /// the result into a pre-allocated buffer.
    ///
    /// This is the zero-allocation variant of ``solve(rhs:)``.
    /// The `result` array must have length equal to the matrix dimension.
    ///
    /// - Parameters:
    ///   - rhs: Right-hand-side vector.
    ///   - result: Pre-allocated output buffer for the solution vector `x`.
    mutating func solve(rhs: [Double], into result: inout [Double]) throws
}

extension LinearSolver {
    /// Default implementation delegates to the allocating ``solve(rhs:)`` variant.
    public mutating func solve(rhs: [Double], into result: inout [Double]) throws {
        let r = try solve(rhs: rhs)
        for i in r.indices { result[i] = r[i] }
    }
}

/// A solver for complex-valued sparse linear systems.
public protocol ComplexLinearSolver: Sendable {

    /// Factorizes the given complex matrix.
    mutating func factorize(matrix: ComplexSparseMatrix) throws

    /// Solves `A * x = rhs` using the stored factorization.
    func solve(rhs: [ComplexPair]) throws -> [ComplexPair]

    /// Solves `A * x = rhs` into a pre-allocated buffer (zero-allocation).
    mutating func solve(rhs: [ComplexPair], into result: inout [ComplexPair]) throws
}

extension ComplexLinearSolver {
    /// Default implementation delegates to the allocating ``solve(rhs:)`` variant.
    public mutating func solve(rhs: [ComplexPair], into result: inout [ComplexPair]) throws {
        let r = try solve(rhs: rhs)
        for i in r.indices { result[i] = r[i] }
    }
}
