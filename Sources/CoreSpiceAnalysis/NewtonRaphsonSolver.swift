import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Accelerate

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
    ) async throws -> (solution: [Double], iterations: Int) {
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
        var vdspTemp = [Double](repeating: 0, count: n)

        // Use local copies so non-@Sendable escaping closures can capture them.
        // The stamping is single-threaded — no synchronisation needed.
        var localMatrix = matrix
        var localRHS = rhs

        // Buffers for the physical KCL residual check at the candidate solution.
        var residualMatrix = matrix
        var residualRHS = [Double](repeating: 0, count: n)

        // Adaptive damping state
        var previousUpdateNorm: Double = .infinity

        for iter in 0..<config.maxIterations {
            if cancellation.isCancelled {
                throw AnalysisError.cancelled
            }

            await observer?.emit(.newtonIterationStarted(NewtonInfo(
                id: analysisID,
                iteration: iter,
                maxIterations: config.maxIterations
            )))

            // Clear matrix and RHS (zero alloc — reuse existing buffers)
            localMatrix.clear()
            localRHS.withUnsafeMutableBufferPointer { buf in
                if let base = buf.baseAddress {
                    memset(base, 0, n &* MemoryLayout<Double>.stride)
                }
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
                },
                stampValue: { idx, val in
                    localMatrix.addValueDirect(at: idx, value: val)
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

            // Compute raw update norm for adaptive damping (vDSP — SIMD accelerated)
            vDSP_vsubD(x, 1, dx, 1, &vdspTemp, 1, vDSP_Length(n))
            var rawUpdateNorm = 0.0
            vDSP_maxmgvD(vdspTemp, 1, &rawUpdateNorm, vDSP_Length(n))

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

            // Device-level voltage limiting on the raw NR solution, applied before
            // damping to prevent overshoot/blow-up. On the first iteration only
            // exponential PN-junction devices are limited (they would otherwise
            // jump to an enormous voltage from the zero initial guess and could not
            // recover); polynomial devices (MOSFETs) keep the unlimited first step
            // so they can reach their operating region freely.
            // After swap: previousX = old x (iter-1), x = stale (will be overwritten).
            for device in devices {
                if let limiter = device as? VoltageLimitingDevice,
                   iter > 0 || limiter.limitsFirstIteration {
                    limiter.limitVoltages(solution: &dx, previousSolution: previousX)
                }
            }

            // Update solution: dx is the full new solution from G*x = s,
            // not a correction. With damping=1 this is direct substitution.
            // vDSP_vintbD: result[i] = A[i] + B * (C[i] - A[i])
            //            = previousX[i] + damping * (dx[i] - previousX[i])
            //            = (1 - damping) * previousX[i] + damping * dx[i]
            var d = damping
            vDSP_vintbD(previousX, 1, dx, 1, &d, &x, 1, vDSP_Length(n))

            // Compute residual norm (vDSP — SIMD accelerated)
            vDSP_vsubD(previousX, 1, x, 1, &vdspTemp, 1, vDSP_Length(n))
            var residualNorm = 0.0
            vDSP_maxmgvD(vdspTemp, 1, &residualNorm, vDSP_Length(n))

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

            // Verify the physical KCL residual F(x) = (G(x) + gmin)·x - s(x) is
            // within tolerance, not just the solution update. Without this a
            // stalled point (e.g. all devices off while an independent current
            // source is unsatisfied) is falsely accepted as converged, silently
            // returning a wrong operating point. Only evaluated once the update
            // criterion is met, so the extra stamp runs at most once per solve.
            if converged {
                residualMatrix.clear()
                for i in 0..<n { residualRHS[i] = 0 }
                var residualStamper = MatrixStamper(
                    variableMap: variableMap,
                    stampMatrix: { row, col, val in
                        residualMatrix.addValue(row: row, col: col, value: val)
                    },
                    stampRHS: { row, val in
                        residualRHS[row] += val
                    },
                    stampValue: { idx, val in
                        residualMatrix.addValueDirect(at: idx, value: val)
                    }
                )
                let residualState = SolutionState(variables: x, variableMap: variableMap)
                stampFunction(&residualStamper, residualState)
                for i in 0..<n {
                    residualMatrix.addValue(row: i, col: i, value: config.gmin)
                }
                let gx = residualMatrix.multiply(vector: x)
                for i in 0..<n {
                    let residual = abs(gx[i] - residualRHS[i])
                    let tol = (branchCurrentIndices.contains(i) ? config.vntol : config.abstol)
                        + config.reltol * abs(residualRHS[i])
                    if residual > tol {
                        converged = false
                        break
                    }
                }
            }

            await observer?.emit(.newtonIterationFinished(NewtonResultInfo(
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

        await observer?.emit(.newtonConvergenceFailure(NewtonFailureInfo(
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
