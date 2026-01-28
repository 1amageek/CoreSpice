import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Synchronization

/// Reusable Newton-Raphson nonlinear iteration engine.
///
/// Solves the nonlinear MNA system `F(x) = 0` by iterating:
///   1. Evaluate the Jacobian `J(x)` and residual `F(x)`.
///   2. Solve `J * dx = -F` for the update `dx`.
///   3. Update `x <- x + damping * dx`.
///   4. Check convergence.
///
/// The caller provides a `stampFunction` closure that populates the
/// Jacobian matrix and RHS vector for a given solution state.
public struct NewtonRaphsonSolver: Sendable {

    /// Convergence configuration controlling tolerances and iteration limits.
    public let config: ConvergenceConfig

    public init(config: ConvergenceConfig = ConvergenceConfig()) {
        self.config = config
    }

    /// Runs Newton-Raphson iteration to solve the nonlinear MNA system.
    ///
    /// - Parameters:
    ///   - initialGuess: Starting solution vector.
    ///   - matrix: The sparse MNA system matrix (modified in place each iteration).
    ///   - rhs: The right-hand-side vector (modified in place each iteration).
    ///   - devices: Bound devices for convergence checking.
    ///   - variableMap: Mapping from MNA variables to matrix indices.
    ///   - solver: The linear solver used for factorization and back-substitution.
    ///   - stampFunction: Closure that stamps device equations into the matrix and RHS.
    ///   - observer: Optional event dispatcher for Newton iteration events.
    ///   - analysisID: The analysis identifier for event correlation.
    ///   - cancellation: Token for cooperative cancellation.
    /// - Returns: The converged solution vector.
    /// - Throws: ``AnalysisError/convergenceFailure(iterations:residualNorm:)`` if iteration
    ///   does not converge, ``AnalysisError/cancelled`` if cancelled, or solver errors.
    public func solve(
        initialGuess: [Double],
        matrix: inout SparseMatrix,
        rhs: inout [Double],
        devices: [any BoundDevice],
        variableMap: [MNAVariable: Int],
        solver: inout any LinearSolver,
        stampFunction: (_ stamper: inout MatrixStamper, _ state: SolutionState) -> Void,
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) throws -> [Double] {
        var x = initialGuess
        let n = x.count

        // Use a Mutex-protected container so the @Sendable closures in
        // MatrixStamper can safely write into the matrix and RHS.
        // Although the stamping is single-threaded, the MatrixStamper
        // interface requires @Sendable closures.
        let matrixStorage = Mutex(matrix)
        let rhsStorage = Mutex(rhs)

        for iter in 0..<config.maxIterations {
            if cancellation.isCancelled {
                throw AnalysisError.cancelled
            }

            observer?.emit(.newtonIterationStarted(NewtonInfo(
                id: analysisID,
                iteration: iter,
                maxIterations: config.maxIterations
            )))

            // Clear matrix and RHS
            matrixStorage.withLock { $0.clear() }
            rhsStorage.withLock { localRhs in
                for i in 0..<n {
                    localRhs[i] = 0.0
                }
            }

            // Build the Jacobian and residual from the current solution
            let state = SolutionState(variables: x, variableMap: variableMap)
            var stamper = MatrixStamper(
                variableMap: variableMap,
                stampMatrix: { row, col, val in
                    matrixStorage.withLock { $0.addValue(row: row, col: col, value: val) }
                },
                stampRHS: { row, val in
                    rhsStorage.withLock { $0[row] += val }
                }
            )

            stampFunction(&stamper, state)

            // Add Gmin to diagonal for numerical stability
            matrixStorage.withLock { mat in
                for i in 0..<n {
                    mat.addValue(row: i, col: i, value: config.gmin)
                }
            }

            // Extract the current matrix and rhs for solving
            let currentMatrix = matrixStorage.withLock { $0 }
            let currentRHS = rhsStorage.withLock { $0 }

            // Factorize and solve the linear system
            do {
                try solver.factorize(matrix: currentMatrix)
            } catch {
                // Write back to inout parameters
                matrix = currentMatrix
                rhs = currentRHS
                throw AnalysisError.singularMatrix
            }

            let dx: [Double]
            do {
                dx = try solver.solve(rhs: currentRHS)
            } catch {
                matrix = currentMatrix
                rhs = currentRHS
                throw AnalysisError.singularMatrix
            }

            // Update solution with damping
            let damping = 1.0
            for i in 0..<n {
                x[i] += damping * dx[i]
            }

            // Compute residual norm (infinity norm of update)
            let residualNorm = dx.map { abs($0) }.max() ?? 0.0
            let converged = config.isConverged(dx: dx, x: x)

            observer?.emit(.newtonIterationFinished(NewtonResultInfo(
                id: analysisID,
                iteration: iter,
                residualNorm: residualNorm,
                damping: damping,
                converged: converged
            )))

            if converged {
                // Write back final state
                matrix = currentMatrix
                rhs = currentRHS
                return x
            }
        }

        // Failed to converge after maximum iterations
        let finalMatrix = matrixStorage.withLock { $0 }
        let finalRHS = rhsStorage.withLock { $0 }
        matrix = finalMatrix
        rhs = finalRHS

        let residual = finalRHS.map { abs($0) }.max() ?? 0.0
        observer?.emit(.newtonConvergenceFailure(NewtonFailureInfo(
            id: analysisID,
            iteration: config.maxIterations,
            residualNorm: residual,
            reason: "Maximum iterations exceeded"
        )))
        throw AnalysisError.convergenceFailure(
            iterations: config.maxIterations,
            residualNorm: residual
        )
    }
}
