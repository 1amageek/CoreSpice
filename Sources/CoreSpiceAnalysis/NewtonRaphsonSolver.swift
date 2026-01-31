import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

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

        // Pre-allocate working buffers (reused across iterations)
        var previousX = [Double](repeating: 0, count: n)
        var dx = [Double](repeating: 0, count: n)

        // Use local copies so non-@Sendable escaping closures can capture them.
        // The stamping is single-threaded — no synchronisation needed.
        var localMatrix = matrix
        var localRHS = rhs

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

            // Clear matrix and RHS (zero alloc — reuse existing buffers)
            localMatrix.clear()
            for i in 0..<n {
                localRHS[i] = 0.0
            }

            // Build the Jacobian and residual from the current solution
            let state = SolutionState(variables: x, variableMap: variableMap)
            var stamper = MatrixStamper(
                variableMap: variableMap,
                stampMatrix: { row, col, val in
                    localMatrix.addValue(row: row, col: col, value: val)
                },
                stampRHS: { row, val in
                    localRHS[row] += val
                }
            )

            stampFunction(&stamper, state)

            // Add Gmin to diagonal for numerical stability
            for i in 0..<n {
                localMatrix.addValue(row: i, col: i, value: config.gmin)
            }

            // Factorize and solve the linear system
            do {
                try solver.factorize(matrix: localMatrix)
            } catch {
                matrix = localMatrix
                rhs = localRHS
                throw AnalysisError.singularMatrix
            }

            do {
                try solver.solve(rhs: localRHS, into: &dx)
            } catch {
                matrix = localMatrix
                rhs = localRHS
                throw AnalysisError.singularMatrix
            }

            // Compute raw update norm for adaptive damping (manual loop — no temp array)
            var rawUpdateNorm = 0.0
            for i in 0..<n {
                let d = abs(dx[i] - x[i])
                if d > rawUpdateNorm { rawUpdateNorm = d }
            }

            // Adaptive damping: reduce step when divergence is detected
            var damping = 1.0
            if rawUpdateNorm > 2.0 * previousUpdateNorm && previousUpdateNorm.isFinite {
                damping = min(1.0, previousUpdateNorm / rawUpdateNorm)
                damping = max(config.minDamping, damping)
            }
            previousUpdateNorm = rawUpdateNorm

            // Save previous solution via O(1) pointer swap, then compute new x
            swap(&x, &previousX)
            // Now: previousX = old x, x = stale buffer (will be overwritten)

            // Update solution: dx is the full new solution from G*x = s,
            // not a correction. With damping=1 this is direct substitution.
            for i in 0..<n {
                x[i] = (1.0 - damping) * previousX[i] + damping * dx[i]
            }

            // Compute residual norm (manual loop — no temp array)
            var residualNorm = 0.0
            for i in 0..<n {
                let d = abs(x[i] - previousX[i])
                if d > residualNorm { residualNorm = d }
            }

            var converged = config.isConverged(
                previousX: previousX, currentX: x,
                branchCurrentIndices: branchCurrentIndices
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
                matrix = localMatrix
                rhs = localRHS
                return (x, iter + 1)
            }
        }

        // Failed to converge after maximum iterations
        matrix = localMatrix
        rhs = localRHS

        var residual = 0.0
        for i in 0..<localRHS.count {
            let a = abs(localRHS[i])
            if a > residual { residual = a }
        }

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
