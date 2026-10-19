import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Foundation

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
    /// Optional global-row units and caller absolute tolerances.
    public let equationPolicy: DCEquationPolicy?
    public let physicalResidualEvaluator: (any NonlinearPhysicalResidualEvaluating)?
    public let physicalResidualEncloser: (any NonlinearPhysicalResidualEnclosing)?
    var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?

    public init(config: ConvergenceConfig = ConvergenceConfig(), equationPolicy: DCEquationPolicy? = nil,
                physicalResidualEvaluator: (any NonlinearPhysicalResidualEvaluating)? = nil,
                physicalResidualEncloser: (any NonlinearPhysicalResidualEnclosing)? = nil) {
        self.physicalResidualEncloser = physicalResidualEncloser
        self.physicalResidualEvaluator = physicalResidualEvaluator
        self.config = config
        self.equationPolicy = equationPolicy
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
        stampFunction: (_ stamper: inout MatrixStamper, _ state: SolutionState) throws -> Void,
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
        stampFunction: (_ stamper: inout MatrixStamper, _ state: SolutionState) throws -> Void,
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> Int {
        var unusedLow: [Double] = []
        return try await solveInternal(initialGuess: initialGuess, initialLowComponents: nil,
            solution: &solution, solutionLowComponents: &unusedLow, matrix: &matrix, rhs: &rhs, devices: devices, variableMap: variableMap,
            solver: &solver, stampFunction: stampFunction, observer: observer,
            analysisID: analysisID, cancellation: cancellation)
    }

    public func solve(
        initialGuess: [Double],
        initialLowComponents: [Double],
        solution: inout [Double],
        solutionLowComponents: inout [Double],
        matrix: inout SparseMatrix,
        rhs: inout [Double],
        devices: [any BoundDevice],
        variableMap: [MNAVariable: Int],
        solver: inout any LinearSolver,
        stampFunction: (_ stamper: inout MatrixStamper, _ state: SolutionState) throws -> Void,
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> Int {
        return try await solveInternal(initialGuess: initialGuess, initialLowComponents: initialLowComponents,
            solution: &solution, solutionLowComponents: &solutionLowComponents, matrix: &matrix, rhs: &rhs, devices: devices, variableMap: variableMap,
            solver: &solver, stampFunction: stampFunction, observer: observer,
            analysisID: analysisID, cancellation: cancellation)
    }

    internal func solveInternal(
        initialGuess: [Double],
        initialLowComponents: [Double]?,
        solution: inout [Double],
        solutionLowComponents: inout [Double],
        matrix: inout SparseMatrix,
        rhs: inout [Double],
        devices: [any BoundDevice],
        variableMap: [MNAVariable: Int],
        solver: inout any LinearSolver,
        stampFunction: (_ stamper: inout MatrixStamper, _ state: SolutionState) throws -> Void,
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> Int {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        let n = initialGuess.count
        let compensated = initialLowComponents != nil
        guard compensated == (physicalResidualEncloser != nil),
              physicalResidualEncloser == nil || physicalResidualEvaluator == nil else {
            throw NumericalStateError.incompatiblePrecisionConfiguration
        }
        if let initialLowComponents {
            try SolutionState(variables: initialGuess, variableMap: variableMap,
                variableLowComponents: initialLowComponents).validateCompensatedComponents()
            guard !devices.contains(where: { $0 is any VoltageLimitingDevice }) else {
                throw NumericalStateError.unsupportedVoltageLimiter
            }
            guard equationPolicy != nil else { throw NumericalStateError.incompatiblePrecisionConfiguration }
        }
        if let equationPolicy {
            try equationPolicy.validate(dimension: n, variableMap: variableMap, config: config)
            guard matrix.structure.dimension == n, rhs.count == n,
                  initialGuess.allSatisfy(\.isFinite) else {
                throw AnalysisError.invalidConfiguration("Explicit DC solve requires matching matrix/vector dimensions and a finite initial guess")
            }
        }
        if executionBudget != nil || resultStorage != nil {
            try solver.configureExecution(AnalysisLinearSolverControl.make(budget: executionBudget,
                cancellation: cancellation, storage: resultStorage))
        }
        try executionBudget?.beginSolve()
        if let initialLowComponents {
            if solutionLowComponents.count != n { solutionLowComponents = [Double](repeating: 0, count: n) }
            for index in 0..<n { solutionLowComponents[index] = initialLowComponents[index] }
        }
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
        var previousLow = compensated ? [Double](repeating: 0, count: n) : []
        var residualRadii = compensated ? [Double](repeating: 0, count: n) : []
        var previousX = [Double](repeating: 0, count: n)
        var dx = [Double](repeating: 0, count: n)
        var vectorScratch = [Double](repeating: 0, count: n)
        var residualProduct = [Double](repeating: 0, count: n)

        // Use local copies so non-@Sendable escaping closures can capture them.
        // The stamping is single-threaded — no synchronisation needed.
        var localMatrix = matrix
        var localRHS = rhs

        // Buffers for the restamped equation residual at the candidate solution.
        var residualMatrix = matrix
        var residualRHS = [Double](repeating: 0, count: n)

        // Adaptive damping state
        var previousUpdateNorm: Double = .infinity
        var lastDamping = 1.0
        let hasVoltageLimiters = devices.contains { $0 is any VoltageLimitingDevice }
        var performedIterations = 0
        var limitingExhausted = false

        for iter in 0..<config.maxIterations {
            performedIterations = iter + 1
            if cancellation.isCancelled || Task.isCancelled {
                throw AnalysisError.cancelled
            }

            try executionBudget?.beginIteration()
            if compensated { try executionBudget?.chargeWork(TransientExecutionBudget.multiply(n, 64, "compensated update work")) }
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
            let state = SolutionState(variables: solution, variableMap: variableMap,
                variableLowComponents: compensated ? solutionLowComponents : nil)
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

            try stampFunction(&stamper, state)

            // Add Gmin to diagonal for numerical stability
            for i in 0..<n where equationPolicy?.rows[i].kind.allowsGmin ?? true {
                localMatrix.addValue(row: i, col: i, value: config.gmin)
            }

            if let physicalResidualEncloser {
                try evaluateResidualEnclosure(physicalResidualEncloser, state: state,
                    residual: &residualProduct, low: &vectorScratch, radii: &residualRadii,
                    nonZeroCount: localMatrix.structure.nonZeroCount, cancellation: cancellation)
                for i in 0..<n { localRHS[i] = -(residualProduct[i] + vectorScratch[i]) }
            } else if let physicalResidualEvaluator {
                try evaluatePhysicalResidual(physicalResidualEvaluator, state: state,
                    residual: &residualProduct, corrections: &vectorScratch,
                    nonZeroCount: localMatrix.structure.nonZeroCount, cancellation: cancellation)
                for i in 0..<n { localRHS[i] = -residualProduct[i] }
            }

            // Factorize and solve the linear system
            do {
                try solver.factorize(matrix: localMatrix)
            } catch {
                matrix = localMatrix
                rhs = localRHS
                if case CompileError.singularMatrix = error { throw AnalysisError.singularMatrix }
                throw error
            }

            do {
                try solver.solve(rhs: localRHS, into: &dx)
            } catch {
                matrix = localMatrix
                rhs = localRHS
                if case CompileError.singularMatrix = error { throw AnalysisError.singularMatrix }
                throw error
            }
            if let invalidIndex = dx.firstIndex(where: { !$0.isFinite }) {
                throw AnalysisError.nonFiniteSolution(
                    iteration: iter,
                    variableIndex: invalidIndex,
                    value: dx[invalidIndex]
                )
            }

            // Improve the original linear system before nonlinear limiting or damping.
            // The two existing scratch buffers remain exclusively mutable here.
            try refineLinearSolution(matrix: localMatrix, rhs: localRHS, solution: &dx,
                scratch: &vectorScratch, residual: &residualProduct, solver: &solver,
                branchCurrentIndices: branchCurrentIndices, iteration: iter,
                cancellation: cancellation)

            if physicalResidualEvaluator != nil {
                // The direct solve produced a correction; existing limiting/damping consume a full candidate.
                for i in 0..<n { dx[i] += solution[i] }
            }

            // Reuse the initialized vectors; no temporary array is materialized.
            let rawUpdateNorm = compensated ? Self.maximumMagnitude(dx)
                : Self.differenceMagnitude(dx, solution, into: &vectorScratch)

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
            if compensated { swap(&solutionLowComponents, &previousLow) }
            // Now: previousX = old x, solution = stale buffer (will be overwritten)

            if hasVoltageLimiters && !compensated {
                guard let admittedDamping = try NewtonVoltageLimiting.apply(
                    raw: dx, previous: previousX, candidate: &solution, scratch: &vectorScratch,
                    devices: devices, firstIteration: iter == 0, damping: damping,
                    maxProbes: config.maxIterations, executionBudget: executionBudget,
                    cancellation: cancellation, iteration: iter
                ) else {
                    limitingExhausted = true
                    break
                }
                damping = admittedDamping
                lastDamping = admittedDamping
            }

            // Update solution: dx is the full new solution from G*x = s,
            // not a correction on the ordinary binary64 path.
            // Preserve subtraction, multiplication, then addition, including overflow.
            if compensated {
                let scale = try CompensatedValue(high: damping)
                for i in 0..<n {
                    let old = try CompensatedValue(high: previousX[i], low: previousLow[i])
                    let update = try CompensatedValue(high: dx[i]).multiplied(by: scale)
                    let candidate = try old.adding(update)
                    solution[i] = candidate.high; solutionLowComponents[i] = candidate.low
                }
            } else if !hasVoltageLimiters {
                Self.interpolate(previousX, dx, damping: damping, into: &solution)
            }
            if let invalidIndex = solution.firstIndex(where: { !$0.isFinite }) {
                throw AnalysisError.nonFiniteSolution(
                    iteration: iter,
                    variableIndex: invalidIndex,
                    value: solution[invalidIndex]
                )
            }

            // Preserve the candidate difference in the existing shared scratch vector.
            var residualNorm = Self.differenceMagnitude(solution, previousX, into: &vectorScratch)

            var converged = try equationPolicy?.isConverged(
                previous: previousX, current: solution, relativeTolerance: config.reltol
            ) ?? config.isConverged(
                previousX: previousX, currentX: solution,
                branchCurrentIndices: branchCurrentIndices
            )

            if compensated {
                converged = true
                residualNorm = 0
                for i in 0..<n {
                    let current = try CompensatedValue(high: solution[i], low: solutionLowComponents[i])
                    let previous = try CompensatedValue(high: previousX[i], low: previousLow[i])
                    let change = try CompensatedEnclosure(center: current).subtracting(
                        CompensatedEnclosure(center: previous)).absoluteUpperBound
                    residualNorm = max(residualNorm, change)
                    let absolute = equationPolicy?.rows[i].variableAbsoluteTolerance
                        ?? (branchCurrentIndices.contains(i) ? config.abstol : config.vntol)
                    let tolerance = config.reltol * abs(current.high) + absolute
                    if change > tolerance { converged = false }
                }
            }

            // Poll per-device convergence when global convergence is met
            if converged {
                let currentState = SolutionState(variables: solution, variableMap: variableMap,
                variableLowComponents: compensated ? solutionLowComponents : nil)
                let prevState = SolutionState(variables: previousX, variableMap: variableMap,
                    variableLowComponents: compensated ? previousLow : nil)
                for device in devices {
                    if case .notConverged = device.checkConvergence(
                        state: currentState, previousState: prevState
                    ) {
                        converged = false
                        break
                    }
                }
            }

            // Re-stamp the candidate and check (G(x) + admitted gmin) * x - rhs(x).
            // This detects stalled updates; caller direct physical validation in
            // DCAnalysis remains independent of cancellation in this linearized form.
            if converged, let physicalResidualEncloser {
                try evaluateResidualEnclosure(physicalResidualEncloser,
                    state: SolutionState(variables: solution, variableMap: variableMap,
                        variableLowComponents: solutionLowComponents),
                    residual: &residualProduct, low: &vectorScratch, radii: &residualRadii,
                    nonZeroCount: localMatrix.structure.nonZeroCount, cancellation: cancellation)
                for i in 0..<n {
                    let enclosed = try CompensatedEnclosure(center: CompensatedValue(high: residualProduct[i], low: vectorScratch[i]),
                        radius: residualRadii[i])
                    let tolerance = equationTolerance(at: i, rhs: localRHS[i], branchCurrentIndices: branchCurrentIndices)
                    if enclosed.radius > tolerance {
                        throw NonlinearPhysicalResidualError.insufficientPrecision(row: i, radius: enclosed.radius, tolerance: tolerance)
                    }
                    if enclosed.absoluteUpperBound > tolerance { converged = false; break }
                }
            } else if converged, let physicalResidualEvaluator {
                try evaluatePhysicalResidual(physicalResidualEvaluator,
                    state: SolutionState(variables: solution, variableMap: variableMap,
                variableLowComponents: compensated ? solutionLowComponents : nil),
                    residual: &residualProduct, corrections: &vectorScratch,
                    nonZeroCount: localMatrix.structure.nonZeroCount, cancellation: cancellation)
                for i in 0..<n {
                    let tolerance = equationTolerance(at: i, rhs: localRHS[i], branchCurrentIndices: branchCurrentIndices)
                    if abs(residualProduct[i]) > tolerance { converged = false; break }
                }
            } else if converged {
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
                let residualState = SolutionState(variables: solution, variableMap: variableMap,
                variableLowComponents: compensated ? solutionLowComponents : nil)
                try stampFunction(&residualStamper, residualState)
                for i in 0..<n where equationPolicy?.rows[i].kind.allowsGmin ?? true {
                    residualMatrix.addValue(row: i, col: i, value: config.gmin)
                }
                if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
                try executionBudget?.chargeAccurateResidual(nonZeroCount: residualMatrix.structure.nonZeroCount)
                try residualMatrix.checkedResidual(vector: solution, rhs: residualRHS, into: &residualProduct)
                for i in 0..<n {
                    let residual = abs(residualProduct[i])
                    guard residual.isFinite else {
                        throw AnalysisError.nonFiniteResidual(
                            iteration: iter,
                            variableIndex: i,
                            value: residual
                        )
                    }
                    let tol = equationTolerance(at: i, rhs: residualRHS[i],
                        branchCurrentIndices: branchCurrentIndices)
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

        if let physicalResidualEncloser {
            try evaluateResidualEnclosure(physicalResidualEncloser,
                state: SolutionState(variables: solution, variableMap: variableMap, variableLowComponents: solutionLowComponents),
                residual: &residualProduct, low: &vectorScratch, radii: &residualRadii,
                nonZeroCount: localMatrix.structure.nonZeroCount, cancellation: cancellation)
        } else if let physicalResidualEvaluator {
            try evaluatePhysicalResidual(physicalResidualEvaluator,
                state: SolutionState(variables: solution, variableMap: variableMap,
                variableLowComponents: compensated ? solutionLowComponents : nil),
                residual: &residualProduct, corrections: &vectorScratch,
                nonZeroCount: localMatrix.structure.nonZeroCount, cancellation: cancellation)
        } else {
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
            try stampFunction(
                &finalResidualStamper,
                SolutionState(variables: solution, variableMap: variableMap,
                variableLowComponents: compensated ? solutionLowComponents : nil)
            )
            for i in 0..<n where equationPolicy?.rows[i].kind.allowsGmin ?? true {
                residualMatrix.addValue(row: i, col: i, value: config.gmin)
            }
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try executionBudget?.chargeAccurateResidual(nonZeroCount: residualMatrix.structure.nonZeroCount)
            try residualMatrix.checkedResidual(vector: solution, rhs: residualRHS, into: &residualProduct)
        }

        var residual = 0.0
        var worstIndex: Int?
        for i in 0..<n {
            let physicalResidual: Double
            if compensated {
                physicalResidual = try CompensatedEnclosure(center: CompensatedValue(high: residualProduct[i], low: vectorScratch[i]),
                    radius: residualRadii[i]).absoluteUpperBound
            } else { physicalResidual = abs(residualProduct[i]) }
            guard physicalResidual.isFinite else {
                throw AnalysisError.nonFiniteResidual(
                    iteration: performedIterations,
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
            iteration: performedIterations,
            residualNorm: residual,
            reason: limitingExhausted ? "Voltage limiting step search exhausted" : "Maximum iterations exceeded",
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
            iterations: performedIterations,
            residualNorm: residual
        )
    }

    // The Array owners retain all initialized Double storage throughout these
    // synchronous borrows. Mutable borrows establish COW uniqueness/exclusivity;
    // read owners may alias each other, but not a mutable destination. No pointer
    // escapes, crosses an await/Sendable boundary, or requires manual deallocation.
    @inline(__always)
    private static func maximumMagnitude(_ values: borrowing [Double]) -> Double {
        values.withUnsafeBufferPointer { vectorMaximumMagnitude($0) }
    }

    @inline(__always)
    private static func differenceMagnitude(_ lhs: borrowing [Double], _ rhs: borrowing [Double],
                                            into scratch: inout [Double]) -> Double {
        lhs.withUnsafeBufferPointer { a in
            rhs.withUnsafeBufferPointer { b in
                scratch.withUnsafeMutableBufferPointer { vectorDifferenceMagnitude(a, b, $0) }
            }
        }
    }

    @inline(__always)
    private static func interpolate(_ previous: borrowing [Double], _ raw: borrowing [Double],
                                    damping: Double, into output: inout [Double]) {
        previous.withUnsafeBufferPointer { a in
            raw.withUnsafeBufferPointer { b in
                output.withUnsafeMutableBufferPointer { vectorInterpolate(a, b, damping: damping, into: $0) }
            }
        }
    }

    // The complete-block bound proves index + 7 < count and index + 8 <= count.
    // The byte-count bound prevents overflow; every accessed byte is initialized.
    // Bitwise raw operations do not rebind Double storage and require no SIMD
    // alignment. The tail remains typed Double access within the same bounds.
    @inline(__always)
    private static func vectorMaximumMagnitude(_ values: UnsafeBufferPointer<Double>) -> Double {
        let count = values.count
        precondition(count <= Int.max / MemoryLayout<Double>.stride)
        precondition(MemoryLayout<SIMD8<Double>>.size == 8 * MemoryLayout<Double>.stride)
        precondition(MemoryLayout<SIMD8<Double>>.size == MemoryLayout<SIMD8<UInt64>>.size)
        guard count > 0 else { return 0 }
        let base = values.baseAddress!
        // A complete 32-value group is required to benefit from the four-chain
        // reduction; shorter inputs retain the original ordered scan directly.
        if count < 32 { return orderedMaximumMagnitude(base, count: count) }
        let wideEnd = count - count % 32
        let end = count - count % 8
        var first = SIMD8<UInt64>(repeating: 0)
        var second = first, third = first, fourth = first
        var index = 0
        // Complete groups prove index + 31 < count; four independent chains
        // avoid making all loads wait on the preceding magnitude comparison.
        while index < wideEnd {
            first = maximumMagnitudeBits(first, loadVector(base, at: index))
            second = maximumMagnitudeBits(second, loadVector(base, at: index + 8))
            third = maximumMagnitudeBits(third, loadVector(base, at: index + 16))
            fourth = maximumMagnitudeBits(fourth, loadVector(base, at: index + 24))
            index += 32
        }
        first = maximumBits(maximumBits(first, second), maximumBits(third, fourth))
        while index < end {
            first = maximumMagnitudeBits(first, loadVector(base, at: index))
            index += 8
        }
        let low = max(max(first[0], first[1]), max(first[2], first[3]))
        let high = max(max(first[4], first[5]), max(first[6], first[7]))
        var bits = max(low, high)
        for i in end..<count { bits = max(bits, base[i].bitPattern & 0x7fff_ffff_ffff_ffff) }
        // Positive IEEE encodings are ordered through +infinity. Any larger
        // encoding is a NaN; repeat the original ordered scan to ignore NaNs
        // exactly, including when every input is NaN. No storage is allocated.
        if bits <= 0x7ff0_0000_0000_0000 { return Double(bitPattern: bits) }
        return orderedMaximumMagnitude(base, count: count)
    }

    @inline(__always)
    private static func orderedMaximumMagnitude(_ base: UnsafePointer<Double>, count: Int) -> Double {
        // The caller already admitted a positive initialized count and byte width.
        // This is the unchanged ordered algorithm for short inputs or NaN input.
        let end = count - count % 8
        var maximum = SIMD8<Double>(repeating: 0)
        var index = 0
        while index < end {
            maximum = maximumMagnitude(maximum, loadVector(base, at: index))
            index += 8
        }
        var norm = reducedMaximum(maximum)
        for i in end..<count { norm = max(norm, abs(base[i])) }
        return norm
    }

    @inline(__always)
    private static func maximumMagnitudeBits(_ maximum: SIMD8<UInt64>,
                                             _ value: SIMD8<Double>) -> SIMD8<UInt64> {
        let bits = unsafeBitCast(value, to: SIMD8<UInt64>.self)
            & SIMD8<UInt64>(repeating: 0x7fff_ffff_ffff_ffff)
        return maximumBits(maximum, bits)
    }

    @inline(__always)
    private static func maximumBits(_ lhs: SIMD8<UInt64>, _ rhs: SIMD8<UInt64>) -> SIMD8<UInt64> {
        lhs.replacing(with: rhs, where: rhs .> lhs)
    }

    @inline(__always)
    private static func vectorDifferenceMagnitude(_ lhs: UnsafeBufferPointer<Double>,
        _ rhs: UnsafeBufferPointer<Double>, _ scratch: UnsafeMutableBufferPointer<Double>) -> Double {
        let count = lhs.count
        precondition(rhs.count == count && scratch.count == count)
        precondition(count <= Int.max / MemoryLayout<Double>.stride)
        precondition(MemoryLayout<SIMD8<Double>>.size == 8 * MemoryLayout<Double>.stride)
        guard count > 0 else { return 0 }
        let a = lhs.baseAddress!, b = rhs.baseAddress!, destination = scratch.baseAddress!
        let end = count - count % 8
        var maximum = SIMD8<Double>(repeating: 0)
        var index = 0
        while index < end {
            let difference = loadVector(a, at: index) - loadVector(b, at: index)
            storeVector(difference, into: destination, at: index)
            maximum = maximumMagnitude(maximum, difference)
            index += 8
        }
        var norm = reducedMaximum(maximum)
        for i in end..<count {
            destination[i] = a[i] - b[i]
            norm = max(norm, abs(destination[i]))
        }
        return norm
    }

    @inline(__always)
    private static func vectorInterpolate(_ previous: UnsafeBufferPointer<Double>,
        _ raw: UnsafeBufferPointer<Double>, damping: Double, into output: UnsafeMutableBufferPointer<Double>) {
        let count = previous.count
        precondition(raw.count == count && output.count == count)
        precondition(count <= Int.max / MemoryLayout<Double>.stride)
        precondition(MemoryLayout<SIMD8<Double>>.size == 8 * MemoryLayout<Double>.stride)
        guard count > 0 else { return }
        let a = previous.baseAddress!, b = raw.baseAddress!, destination = output.baseAddress!
        let end = count - count % 8
        let scale = SIMD8<Double>(repeating: damping)
        var index = 0
        while index < end {
            let old = loadVector(a, at: index)
            let difference = loadVector(b, at: index) - old
            let scaled = scale * difference
            storeVector(old + scaled, into: destination, at: index)
            index += 8
        }
        for i in end..<count { destination[i] = a[i] + damping * (b[i] - a[i]) }
    }

    @inline(__always)
    private static func loadVector(_ values: UnsafePointer<Double>, at index: Int) -> SIMD8<Double> {
        UnsafeRawPointer(values.advanced(by: index)).loadUnaligned(as: SIMD8<Double>.self)
    }

    @inline(__always)
    private static func storeVector(_ value: SIMD8<Double>, into values: UnsafeMutablePointer<Double>, at index: Int) {
        UnsafeMutableRawPointer(values.advanced(by: index)).storeBytes(of: value, as: SIMD8<Double>.self)
    }

    @inline(__always)
    private static func maximumMagnitude(_ maximum: SIMD8<Double>, _ value: SIMD8<Double>) -> SIMD8<Double> {
        // Value-only IEEE binary64 sign clearing: no pointer reinterpretation or
        // binding change. NaN compares false, so each lane remains ordered and
        // nonnegative (including canonical +0 and +infinity).
        precondition(MemoryLayout<SIMD8<Double>>.size == MemoryLayout<SIMD8<UInt64>>.size)
        let bits = unsafeBitCast(value, to: SIMD8<UInt64>.self)
            & SIMD8<UInt64>(repeating: 0x7fff_ffff_ffff_ffff)
        let magnitude = unsafeBitCast(bits, to: SIMD8<Double>.self)
        return maximum.replacing(with: magnitude, where: magnitude .>= maximum)
    }

    @inline(__always)
    private static func reducedMaximum(_ value: SIMD8<Double>) -> Double {
        // Only maximumMagnitude's initialized, non-NaN lanes reach this tree.
        let first = max(max(value[0], value[1]), max(value[2], value[3]))
        let second = max(max(value[4], value[5]), max(value[6], value[7]))
        return max(first, second)
    }

    /// Reuses the stored factors and existing Newton scratch buffers. No iterate is
    /// published until the unchanged nonlinear update/device/physical gates pass.
    private func refineLinearSolution(
        matrix: borrowing SparseMatrix, rhs: borrowing [Double],
        solution: inout [Double], scratch: inout [Double], residual: inout [Double],
        solver: inout any LinearSolver, branchCurrentIndices: Set<Int>,
        iteration: Int, cancellation: CancellationToken
    ) throws {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        try executionBudget?.chargeAccurateResidual(nonZeroCount: matrix.structure.nonZeroCount)
        try matrix.checkedResidual(vector: solution, rhs: rhs, into: &residual)
        var bestQuality = try maximumNormalizedResidual(residual, rhs: rhs,
            branchCurrentIndices: branchCurrentIndices, iteration: iteration)
        for _ in 0..<config.maxIterations {
            if bestQuality <= 1 { break }
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try executionBudget?.beginRefinementSolve()
            for i in residual.indices { residual[i] = -residual[i] }
            do {
                try solver.solve(rhs: residual, into: &scratch)
            } catch {
                if case CompileError.singularMatrix = error { throw AnalysisError.singularMatrix }
                throw error
            }
            var changed = false
            for i in solution.indices {
                scratch[i] += solution[i]
                guard scratch[i].isFinite else {
                    throw AnalysisError.nonFiniteSolution(iteration: iteration,
                        variableIndex: i, value: scratch[i])
                }
                changed = changed || scratch[i].bitPattern != solution[i].bitPattern
            }
            if !changed { break }
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try executionBudget?.chargeAccurateResidual(nonZeroCount: matrix.structure.nonZeroCount)
            try matrix.checkedResidual(vector: scratch, rhs: rhs, into: &residual)
            let quality = try maximumNormalizedResidual(residual, rhs: rhs,
                branchCurrentIndices: branchCurrentIndices, iteration: iteration)
            if quality >= bestQuality { break }
            swap(&solution, &scratch)
            bestQuality = quality
        }
    }

    private func maximumNormalizedResidual(
        _ residual: borrowing [Double], rhs: borrowing [Double],
        branchCurrentIndices: Set<Int>, iteration: Int
    ) throws -> Double {
        var maximum = 0.0
        for i in residual.indices {
            let value = abs(residual[i])
            guard value.isFinite else {
                throw AnalysisError.nonFiniteResidual(iteration: iteration,
                    variableIndex: i, value: value)
            }
            let tolerance = equationTolerance(at: i, rhs: rhs[i],
                branchCurrentIndices: branchCurrentIndices)
            guard tolerance.isFinite, tolerance >= 0 else {
                throw AnalysisError.invalidConfiguration("Newton residual tolerance must be finite and nonnegative")
            }
            // Infinity is an ordered quality for a finite residual at zero tolerance;
            // it is never a successful gate or a non-finite physical residual.
            let quality = tolerance == 0 ? (value == 0 ? 0 : Double.infinity) : value / tolerance
            maximum = max(maximum, quality)
        }
        return maximum
    }

    /// Reuses two exclusive Newton vectors; callback terms never index storage before validation.
    private func evaluatePhysicalResidual(
        _ evaluator: any NonlinearPhysicalResidualEvaluating, state: SolutionState,
        residual: inout [Double], corrections: inout [Double], nonZeroCount: Int, cancellation: CancellationToken
    ) throws {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        try executionBudget?.chargeAccurateResidual(nonZeroCount: nonZeroCount)
        for index in residual.indices { residual[index] = 0; corrections[index] = 0 }
        var failure: NonlinearPhysicalResidualError?
        func add(_ row: Int, _ value: Double) {
            guard failure == nil else { return }
            guard residual.indices.contains(row) else {
                failure = .invalidRow(row: row, dimension: residual.count); return
            }
            guard value.isFinite else { failure = .nonfiniteContribution(row: row, value: value); return }
            let sum = residual[row], next = sum + value
            let correction = abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
            residual[row] = next
            corrections[row] += correction
            if !next.isFinite || !corrections[row].isFinite {
                failure = .nonfiniteContribution(row: row, value: next)
            }
        }
        try evaluator.accumulateResidual(state: state, add: add)
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        if let failure { throw failure }
        for index in residual.indices {
            if equationPolicy?.rows[index].kind.allowsGmin ?? true { add(index, config.gmin * state.variables[index]) }
        }
        if let failure { throw failure }
        for index in residual.indices {
            residual[index] += corrections[index]
            guard residual[index].isFinite else {
                throw NonlinearPhysicalResidualError.nonfiniteContribution(row: index, value: residual[index])
            }
        }
    }

    /// Reuses two center vectors and one admitted radius vector; no callback can publish history.
    internal func evaluateResidualEnclosure(
        _ evaluator: any NonlinearPhysicalResidualEnclosing, state: SolutionState,
        residual: inout [Double], low: inout [Double], radii: inout [Double],
        nonZeroCount: Int, cancellation: CancellationToken
    ) throws {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        try executionBudget?.chargeAccurateResidual(nonZeroCount: nonZeroCount)
        try executionBudget?.chargeWork(TransientExecutionBudget.multiply(residual.count, 128, "enclosed residual work"))
        for index in residual.indices { residual[index] = 0; low[index] = 0; radii[index] = 0 }
        var failure: (any Error)?
        func add(_ row: Int, _ center: CompensatedValue, _ radius: Double) {
            guard failure == nil else { return }
            guard residual.indices.contains(row) else {
                failure = NonlinearPhysicalResidualError.invalidRow(row: row, dimension: residual.count); return
            }
            do {
                let current = try CompensatedEnclosure(center: CompensatedValue(high: residual[row], low: low[row]), radius: radii[row])
                let next = try current.adding(CompensatedEnclosure(center: center, radius: radius))
                residual[row] = next.center.high; low[row] = next.center.low; radii[row] = next.radius
            } catch { failure = error }
        }
        try evaluator.accumulateResidualEnclosure(state: state, add: add)
        if let failure { throw failure }
        for index in residual.indices where equationPolicy?.rows[index].kind.allowsGmin ?? true {
            let term = try CompensatedEnclosure(center: state.checkedCompensatedValue(at: index))
                .multiplied(by: CompensatedEnclosure(center: CompensatedValue(high: config.gmin)))
            add(index, term.center, term.radius)
        }
        if let failure { throw failure }
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
    }

    private func equationTolerance(at index: Int, rhs: Double, branchCurrentIndices: Set<Int>) -> Double {
        if let equationPolicy { return equationPolicy.rows[index].equationAbsoluteTolerance }
        return (branchCurrentIndices.contains(index) ? config.vntol : config.abstol) + config.reltol * abs(rhs)
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
