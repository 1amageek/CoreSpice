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
        var solution = [Double](repeating: 0.0, count: initialGuess.count)
        let iterations = try await solve(
            initialGuess: initialGuess,
            solution: &solution,
            matrix: &matrix,
            rhs: &rhs,
            devices: devices,
            variableMap: variableMap,
            solver: &solver,
            stampFunction: stampFunction,
            observer: observer,
            analysisID: analysisID,
            cancellation: cancellation
        )
        return (solution, iterations)
    }

    /// Runs Newton-Raphson iteration and writes the converged solution into
    /// caller-owned storage.
    ///
    /// The `solution` buffer is reused across iterations, avoiding the final
    /// solution allocation and allowing callers to rotate ownership with their
    /// own working buffers.
    public func solve(
        initialGuess: [Double],
        solution: inout [Double],
        matrix: inout SparseMatrix,
        rhs: inout [Double],
        devices: [any BoundDevice],
        variableMap: [MNAVariable: Int],
        solver: inout any LinearSolver,
        stampFunction: (_ stamper: inout MatrixStamper, _ state: SolutionState) -> Void,
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> Int {
        let n = initialGuess.count
        if solution.count != n {
            solution = [Double](repeating: 0.0, count: n)
        }
        initialGuess.withUnsafeBufferPointer { src in
            solution.withUnsafeMutableBufferPointer { dst in
                if let srcBase = src.baseAddress, let dstBase = dst.baseAddress {
                    dstBase.update(from: srcBase, count: n)
                }
            }
        }

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
        var residualProduct = [Double](repeating: 0, count: n)

        // Use local copies so non-@Sendable escaping closures can capture them.
        // The stamping is single-threaded — no synchronisation needed.
        var localMatrix = matrix
        var localRHS = rhs

        // Buffers for the physical KCL residual check at the candidate solution.
        var residualMatrix = matrix
        var residualRHS = [Double](repeating: 0, count: n)

        // Adaptive damping state
        var previousUpdateNorm: Double = .infinity
        var lastDamping = 1.0

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
            let state = SolutionState(variables: solution, variableMap: variableMap)
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
            if let invalidIndex = dx.firstIndex(where: { !$0.isFinite }) {
                throw AnalysisError.nonFiniteSolution(
                    iteration: iter,
                    variableIndex: invalidIndex,
                    value: dx[invalidIndex]
                )
            }

            // Compute raw update norm for adaptive damping (vDSP — SIMD accelerated)
            vDSP_vsubD(solution, 1, dx, 1, &vdspTemp, 1, vDSP_Length(n))
            var rawUpdateNorm = 0.0
            vDSP_maxmgvD(vdspTemp, 1, &rawUpdateNorm, vDSP_Length(n))

            // Adaptive damping: reduce step when divergence is detected
            var damping = 1.0
            if rawUpdateNorm > 2.0 * previousUpdateNorm && previousUpdateNorm.isFinite {
                damping = min(1.0, previousUpdateNorm / rawUpdateNorm)
                damping = max(config.minDamping, damping)
            }
            previousUpdateNorm = rawUpdateNorm
            lastDamping = damping

            // Save previous solution via O(1) pointer swap, then compute new x
            swap(&solution, &previousX)
            // Now: previousX = old x, solution = stale buffer (will be overwritten)

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
            vDSP_vintbD(previousX, 1, dx, 1, &d, &solution, 1, vDSP_Length(n))
            if let invalidIndex = solution.firstIndex(where: { !$0.isFinite }) {
                throw AnalysisError.nonFiniteSolution(
                    iteration: iter,
                    variableIndex: invalidIndex,
                    value: solution[invalidIndex]
                )
            }

            // Compute residual norm (vDSP — SIMD accelerated)
            vDSP_vsubD(previousX, 1, solution, 1, &vdspTemp, 1, vDSP_Length(n))
            var residualNorm = 0.0
            vDSP_maxmgvD(vdspTemp, 1, &residualNorm, vDSP_Length(n))

            var converged = config.isConverged(
                previousX: previousX, currentX: solution,
                branchCurrentIndices: branchCurrentIndices
            )


            // Poll per-device convergence when global convergence is met
            if converged {
                let currentState = SolutionState(variables: solution, variableMap: variableMap)
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
                let residualState = SolutionState(variables: solution, variableMap: variableMap)
                stampFunction(&residualStamper, residualState)
                for i in 0..<n {
                    residualMatrix.addValue(row: i, col: i, value: config.gmin)
                }
                try residualMatrix.checkedMultiply(vector: solution, into: &residualProduct)
                for i in 0..<n {
                    let residual = abs(residualProduct[i] - residualRHS[i])
                    guard residual.isFinite else {
                        throw AnalysisError.nonFiniteResidual(
                            iteration: iter,
                            variableIndex: i,
                            value: residual
                        )
                    }
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
                return iter + 1
            }
        }

        // Failed to converge after maximum iterations
        matrix = localMatrix
        rhs = localRHS

        residualMatrix.clear()
        for i in 0..<n {
            residualRHS[i] = 0
        }
        var finalResidualStamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, col, value in
                residualMatrix.addValue(row: row, col: col, value: value)
            },
            stampRHS: { row, value in
                residualRHS[row] += value
            },
            stampValue: { index, value in
                residualMatrix.addValueDirect(at: index, value: value)
            }
        )
        stampFunction(
            &finalResidualStamper,
            SolutionState(variables: solution, variableMap: variableMap)
        )
        for i in 0..<n {
            residualMatrix.addValue(row: i, col: i, value: config.gmin)
        }
        try residualMatrix.checkedMultiply(vector: solution, into: &residualProduct)

        var residual = 0.0
        var worstIndex: Int?
        for i in 0..<n {
            let physicalResidual = abs(residualProduct[i] - residualRHS[i])
            guard physicalResidual.isFinite else {
                throw AnalysisError.nonFiniteResidual(
                    iteration: config.maxIterations,
                    variableIndex: i,
                    value: physicalResidual
                )
            }
            if physicalResidual > residual {
                residual = physicalResidual
                worstIndex = i
            }
        }
        let worstVariable = worstIndex.flatMap { variableName(for: $0, variableMap: variableMap) }

        await observer?.emit(.newtonConvergenceFailure(NewtonFailureInfo(
            id: analysisID,
            iteration: config.maxIterations,
            residualNorm: residual,
            reason: "Maximum iterations exceeded",
            worstVariable: worstVariable,
            worstVariableIndex: worstIndex,
            finalDamping: lastDamping,
            suggestedActions: [
                "inspect_worst_kcl_variable",
                "try_gmin_stepping",
                "try_source_stepping",
                "provide_initial_condition_or_nodeset",
                "check_nonlinear_device_parameters"
            ]
        )))
        throw AnalysisError.convergenceFailure(
            iterations: config.maxIterations,
            residualNorm: residual
        )
    }

    private func variableName(
        for index: Int,
        variableMap: [MNAVariable: Int]
    ) -> String? {
        for (variable, mappedIndex) in variableMap where mappedIndex == index {
            return String(describing: variable)
        }
        return nil
    }
}
