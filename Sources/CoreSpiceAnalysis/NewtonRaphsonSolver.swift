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
    /// - Returns: A tuple of the converged solution vector and the number of iterations performed.
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
    ) throws -> (solution: [Double], iterations: Int) {
        var x = initialGuess
        let n = x.count

        // Extract branch current indices for per-variable convergence tolerances
        let branchCurrentIndices: Set<Int> = Set(
            variableMap.compactMap { key, value in
                if case .branchCurrent = key { return value }
                return nil
            }
        )

        // Use a Mutex-protected container so the @Sendable closures in
        // MatrixStamper can safely write into the matrix and RHS.
        // Although the stamping is single-threaded, the MatrixStamper
        // interface requires @Sendable closures.
        let matrixStorage = Mutex(matrix)
        let rhsStorage = Mutex(rhs)

        // Adaptive damping state
        var previousUpdateNorm: Double = .infinity

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

            // Save previous solution for convergence check
            let previousX = x

            // Compute raw update norm for adaptive damping
            let rawUpdateNorm = (0..<n).map { abs(dx[$0] - x[$0]) }.max() ?? 0.0

            // Adaptive damping: reduce step when divergence is detected
            var damping = 1.0
            if rawUpdateNorm > 2.0 * previousUpdateNorm && previousUpdateNorm.isFinite {
                damping = min(1.0, previousUpdateNorm / rawUpdateNorm)
                damping = max(config.minDamping, damping)
            }
            previousUpdateNorm = rawUpdateNorm

            // Update solution: dx is the full new solution from G*x = s,
            // not a correction. With damping=1 this is direct substitution.
            for i in 0..<n {
                x[i] = (1.0 - damping) * x[i] + damping * dx[i]
            }

            // Compute residual norm (infinity norm of solution change)
            let update = (0..<n).map { x[$0] - previousX[$0] }
            let residualNorm = update.map { abs($0) }.max() ?? 0.0
            var converged = config.isConverged(
                dx: update, x: x, branchCurrentIndices: branchCurrentIndices
            )

            // Poll per-device convergence when global convergence is met
            if converged {
                let currentState = SolutionState(variables: x, variableMap: variableMap)
                let prevState = SolutionState(variables: previousX, variableMap: variableMap)
                for device in devices {
                    if case .notConverged = device.checkConvergence(
                        state: currentState, previousState: prevState
                    ) {
                        converged = false
                        break
                    }
                }
            }

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
                return (x, iter + 1)
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
