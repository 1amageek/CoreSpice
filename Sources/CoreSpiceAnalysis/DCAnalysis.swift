import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

/// DC operating point analysis.
///
/// Finds the steady-state (DC) solution of the circuit by solving
/// the nonlinear MNA system `F(x) = 0` using Newton-Raphson iteration.
///
/// If the primary Newton-Raphson solve fails to converge, the analysis
/// falls back to Gmin stepping and then source stepping as convergence aids.
public struct DCAnalysis: Analysis, Sendable {

    public typealias Result = DCResult
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?

    /// Convergence configuration for the Newton-Raphson solver.
    public let config: ConvergenceConfig

    /// Coordinate precision selection; automatic requires complete device capability.
    public let precisionMode: DCPrecisionMode

    /// Gmin stepping parameters for convergence assistance.
    public let gminStepping: GminStepping

    /// Source stepping parameters for convergence assistance.
    public let sourceStepping: SourceStepping

    /// Explicit per-global-row units and tolerances; nil preserves the legacy profile.
    public let equationPolicy: DCEquationPolicy?

    /// Final original-equation validation before accepted state and completed publication.
    public let physicalResidualValidator: (any DCPhysicalResidualValidating)?

    /// Node-coordinate guesses used as the Newton starting point.
    /// Explicit thermal rows use temperature rise in K; electrical nodes use V.
    public let completionFinalizer: (any AnalysisCompletionFinalizing)?

    public let nodeInitialGuess: [Node: Double]

    public init(
        config: ConvergenceConfig = ConvergenceConfig(),
        gminStepping: GminStepping = GminStepping(),
        sourceStepping: SourceStepping = SourceStepping(),
        nodeInitialGuess: [Node: Double] = [:],
        equationPolicy: DCEquationPolicy? = nil,
        physicalResidualValidator: (any DCPhysicalResidualValidating)? = nil,
        completionFinalizer: (any AnalysisCompletionFinalizing)? = nil,
        precisionMode: DCPrecisionMode = .automatic
    ) {
        self.completionFinalizer = completionFinalizer
        self.config = config
        self.gminStepping = gminStepping
        self.sourceStepping = sourceStepping
        self.nodeInitialGuess = nodeInitialGuess
        self.equationPolicy = equationPolicy
        self.physicalResidualValidator = physicalResidualValidator
        self.precisionMode = precisionMode
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> DCResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .dc,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            let precision = try DCDevicePhysicalResidualEncloser.select(mode: precisionMode,
                devices: devices, variableMap: variableMap, dimension: dim,
                hasOptics: plan.opticalNetwork != nil, config: config, policy: equationPolicy)
            let policy = precision?.policy ?? equationPolicy
            try policy?.validate(dimension: dim, variableMap: variableMap, config: config)
            if precision != nil { try executionBudget?.admitSavedScalars(dim) }
            if policy != nil {
                guard gminStepping.initialGmin.isFinite, gminStepping.initialGmin >= 0,
                      gminStepping.finalGmin.isFinite, gminStepping.finalGmin >= 0,
                      gminStepping.reductionFactor.isFinite, gminStepping.reductionFactor > 1,
                      gminStepping.maxSteps >= 0, sourceStepping.steps > 0 else {
                    throw AnalysisError.invalidConfiguration("Explicit DC recovery requires valid gmin stages and positive source steps")
                }
            }
            // Share one solver instance across all phases so that
            // the SymbolicAnalysis cache and workspace buffers are reused.
            var mutableSolver = solver

            // Phase 1: Direct Newton-Raphson
            let initialGuess = try buildInitialGuess(
                plan: plan,
                variableMap: variableMap,
                dimension: dim
            )
            var result: DCResult
            var finalStageGmin = config.gmin
            do {
                result = try await solveNR(
                    config: config,
                    initialGuess: initialGuess,
                    initialLowComponents: nil,
                    precision: precision,
                    plan: plan,
                    devices: devices,
                    solver: &mutableSolver,
                    variableMap: variableMap,
                    observer: observer,
                    analysisID: analysisID,
                    cancellation: cancellation
                )
            } catch let error as AnalysisError {
                guard case .convergenceFailure = error else { throw error }

                // Phase 2: Gmin stepping
                do {
                    let stepped = try await solveWithGminStepping(
                        plan: plan,
                        devices: devices,
                        initialGuess: initialGuess,
                        precision: precision,
                        solver: &mutableSolver,
                        variableMap: variableMap,
                        observer: observer,
                        analysisID: analysisID,
                        cancellation: cancellation
                    )
                    result = stepped
                    finalStageGmin = gminStepping.finalGmin
                } catch let error as AnalysisError {
                    guard case .convergenceFailure = error else { throw error }
                    // Phase 3: Source stepping
                    result = try await solveWithSourceStepping(
                        plan: plan,
                        devices: devices,
                        initialGuess: initialGuess,
                        precision: precision,
                        solver: &mutableSolver,
                        variableMap: variableMap,
                        observer: observer,
                        analysisID: analysisID,
                        cancellation: cancellation
                    )
                    finalStageGmin = config.gmin
                }
            }

            if finalStageGmin != 0 {
                // Remove actual recovery regularization before original-circuit publication.
                var finalConfig = config
                finalConfig.gmin = 0
                let polished = try await solveNR(config: finalConfig, initialGuess: result.variables,
                    initialLowComponents: result.variableLowComponents, precision: precision,
                    plan: plan, devices: devices, solver: &mutableSolver, variableMap: variableMap,
                    observer: observer, analysisID: analysisID, cancellation: cancellation)
                result = try DCResult(variables: polished.variables, variableMap: variableMap,
                    iterations: try TransientExecutionBudget.add(result.iterations, polished.iterations,
                        "DC polish iterations"), opticalState: polished.opticalState,
                    variableLowComponents: polished.variableLowComponents)
            }
            if let precision {
                try certifyOriginalEquations(result: result, precision: precision, plan: plan,
                    cancellation: cancellation)
            }

            let acceptedState = SolutionState(
                variables: result.variables,
                variableMap: variableMap,
                variableLowComponents: result.variableLowComponents
            )
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try physicalResidualValidator?.validate(state: acceptedState)
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            for device in devices {
                if let committingDevice = device as? any AcceptedStateCommittingDevice {
                    committingDevice.commitAcceptedState(acceptedState)
                }
            }

            try completionFinalizer?.finalizeCompletion()
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .dc,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return result
        } catch {
            let status: AnalysisStatus
            if let analysisError = error as? AnalysisError {
                if case .cancelled = analysisError {
                    status = .cancelled
                } else {
                    status = .failed
                }
            } else {
                status = .failed
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .dc,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    // MARK: - Private

    private func solveNR(
        config: ConvergenceConfig,
        initialGuess: [Double],
        initialLowComponents: [Double]?,
        precision: DCDevicePhysicalResidualEncloser?,
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: inout any LinearSolver,
        variableMap: [MNAVariable: Int],
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken,
        sourceScale: Double = 1
    ) async throws -> DCResult {
        var matrix = SparseMatrix(structure: plan.matrixStructure)
        var rhs = [Double](repeating: 0, count: plan.topology.dimension)

        // Optical network evaluation state (captured by stampFunction closure).
        // Updated at each NR iteration so the Jacobian includes optical-electrical coupling.
        let evaluator = OpticalNetworkEvaluator()
        var opticalState = OpticalState(
            nodeCount: plan.opticalNetwork?.opticalNodeCount ?? 0
        )

        let encloser = precision?.scalingSources(by: sourceScale)
        var nr = NewtonRaphsonSolver(config: config, equationPolicy: precision?.policy ?? equationPolicy,
            physicalResidualEncloser: encloser)
        nr.executionBudget = executionBudget
        nr.resultStorage = resultStorage
        var solution = [Double](repeating: 0.0, count: initialGuess.count)
        var low = precision == nil ? [] : (initialLowComponents ?? [Double](repeating: 0, count: initialGuess.count))
        let stampFunction = { (stamper: inout MatrixStamper, state: SolutionState) throws in
                // 1a. Evaluate optical network (DAG topological order)
                if let graph = plan.opticalNetwork {
                    opticalState = evaluator.evaluate(
                        graph: graph,
                        devices: devices,
                        electricalState: state,
                        previousOpticalState: opticalState
                    )
                }
                // 1b. Stamp all devices (type-checked dispatch)
                for device in devices {
                    if sourceScale != 1, let source = device as? BoundVoltageSource {
                        source.stampDCScaled(into: &stamper, state: state, factor: sourceScale)
                    } else if sourceScale != 1, let source = device as? BoundCurrentSource {
                        source.stampDCScaled(into: &stamper, state: state, factor: sourceScale)
                    } else if let optoDevice = device as? OptoelectronicDevice {
                        optoDevice.stampDC(into: &stamper, state: state, opticalState: opticalState)
                    } else {
                        try device.stampDC(into: &stamper, state: state)
                    }
                }
            }
        let iterations: Int
        if precision != nil {
            let initialLow = low
            iterations = try await nr.solve(initialGuess: initialGuess, initialLowComponents: initialLow,
                solution: &solution, solutionLowComponents: &low, matrix: &matrix, rhs: &rhs,
                devices: devices, variableMap: variableMap, solver: &solver, stampFunction: stampFunction,
                observer: observer, analysisID: analysisID, cancellation: cancellation)
        } else {
            iterations = try await nr.solve(initialGuess: initialGuess, solution: &solution,
                matrix: &matrix, rhs: &rhs, devices: devices, variableMap: variableMap,
                solver: &solver, stampFunction: stampFunction, observer: observer,
                analysisID: analysisID, cancellation: cancellation)
        }

        return try DCResult(
            variables: solution,
            variableMap: variableMap,
            iterations: iterations,
            opticalState: plan.opticalNetwork != nil ? opticalState : nil,
            variableLowComponents: precision == nil ? nil : low
        )
    }

    private func solveWithGminStepping(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        initialGuess: [Double],
        precision: DCDevicePhysicalResidualEncloser?,
        solver: inout any LinearSolver,
        variableMap: [MNAVariable: Int],
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> DCResult {
        var x = initialGuess
        var low: [Double]?
        var totalIterations = 0

        for gmin in gminStepping.lazyValues() {
            var stepConfig = config
            stepConfig.gmin = gmin

            let result = try await solveNR(
                config: stepConfig,
                initialGuess: x,
                initialLowComponents: low,
                precision: precision,
                plan: plan,
                devices: devices,
                solver: &solver,
                variableMap: variableMap,
                observer: observer,
                analysisID: analysisID,
                cancellation: cancellation
            )
            x = result.variables
            low = result.variableLowComponents
            totalIterations = try TransientExecutionBudget.add(totalIterations, result.iterations,
                "DC gmin recovery iterations")
        }

        return try DCResult(
            variables: x,
            variableMap: variableMap,
            iterations: totalIterations,
            variableLowComponents: low
        )
    }

    private func solveWithSourceStepping(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        initialGuess: [Double],
        precision: DCDevicePhysicalResidualEncloser?,
        solver: inout any LinearSolver,
        variableMap: [MNAVariable: Int],
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> DCResult {
        guard let precision else {
            return try await solveWithBinary64SourceStepping(plan: plan, devices: devices,
                initialGuess: initialGuess, solver: &solver, variableMap: variableMap,
                observer: observer, analysisID: analysisID, cancellation: cancellation)
        }
        var x = initialGuess
        var low: [Double]?
        var totalIterations = 0
        var opticalState: OpticalState?
        for step in 1...sourceStepping.steps {
            let factor = Double(step) / Double(sourceStepping.steps)
            let result = try await solveNR(config: config, initialGuess: x,
                initialLowComponents: low, precision: precision, plan: plan, devices: devices,
                solver: &solver, variableMap: variableMap, observer: observer,
                analysisID: analysisID, cancellation: cancellation, sourceScale: factor)
            x = result.variables
            low = result.variableLowComponents
            opticalState = result.opticalState
            totalIterations = try TransientExecutionBudget.add(totalIterations, result.iterations,
                "DC source recovery iterations")
        }
        return try DCResult(variables: x, variableMap: variableMap, iterations: totalIterations,
            opticalState: opticalState, variableLowComponents: low)
    }

    private func solveWithBinary64SourceStepping(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        initialGuess: [Double],
        solver: inout any LinearSolver,
        variableMap: [MNAVariable: Int],
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> DCResult {
        let dim = plan.topology.dimension
        var x = initialGuess
        var solution = [Double](repeating: 0, count: dim)
        var totalIterations = 0
        var matrix = SparseMatrix(structure: plan.matrixStructure)
        var rhs = [Double](repeating: 0, count: dim)

        // Optical network evaluation state (persists across source stepping factors)
        let evaluator = OpticalNetworkEvaluator()
        var opticalState = OpticalState(
            nodeCount: plan.opticalNetwork?.opticalNodeCount ?? 0
        )

        for factor in (1...sourceStepping.steps).lazy.map({ Double($0) / Double(sourceStepping.steps) }) {
            var nr = NewtonRaphsonSolver(config: config, equationPolicy: equationPolicy)
            nr.executionBudget = executionBudget
            nr.resultStorage = resultStorage
            let iterations = try await nr.solve(
                initialGuess: x,
                solution: &solution,
                matrix: &matrix,
                rhs: &rhs,
                devices: devices,
                variableMap: variableMap,
                solver: &solver,
                stampFunction: { stamper, state in
                    // Evaluate optical network
                    if let graph = plan.opticalNetwork {
                        opticalState = evaluator.evaluate(
                            graph: graph,
                            devices: devices,
                            electricalState: state,
                            previousOpticalState: opticalState
                        )
                    }
                    // Stamp each device, applying source scaling to independent sources
                    for device in devices {
                        if let vsource = device as? BoundVoltageSource {
                            vsource.stampDCScaled(into: &stamper, state: state, factor: factor)
                        } else if let isource = device as? BoundCurrentSource {
                            isource.stampDCScaled(into: &stamper, state: state, factor: factor)
                        } else if let optoDevice = device as? OptoelectronicDevice {
                            optoDevice.stampDC(into: &stamper, state: state, opticalState: opticalState)
                        } else {
                            try device.stampDC(into: &stamper, state: state)
                        }
                    }
                },
                observer: observer,
                analysisID: analysisID,
                cancellation: cancellation
            )
            swap(&x, &solution)
            totalIterations += iterations
        }

        return try DCResult(
            variables: x,
            variableMap: variableMap,
            iterations: totalIterations,
            opticalState: plan.opticalNetwork != nil ? opticalState : nil
        )
    }

    private func certifyOriginalEquations(result: DCResult,
        precision: DCDevicePhysicalResidualEncloser, plan: ExecutionPlan,
        cancellation: CancellationToken) throws {
        let count = result.variables.count
        var residual = [Double](repeating: 0, count: count)
        var low = [Double](repeating: 0, count: count)
        var radii = [Double](repeating: 0, count: count)
        var finalConfig = config
        finalConfig.gmin = 0
        var gate = NewtonRaphsonSolver(config: finalConfig, equationPolicy: precision.policy,
            physicalResidualEncloser: precision)
        gate.executionBudget = executionBudget
        try gate.evaluateResidualEnclosure(precision,
            state: SolutionState(variables: result.variables, variableMap: result.variableMap,
                variableLowComponents: result.variableLowComponents),
            residual: &residual, low: &low, radii: &radii,
            nonZeroCount: plan.matrixStructure.nonZeroCount, cancellation: cancellation)
        for index in residual.indices {
            let enclosure = try CompensatedEnclosure(
                center: CompensatedValue(high: residual[index], low: low[index]), radius: radii[index])
            let tolerance = precision.policy.rows[index].equationAbsoluteTolerance
            guard enclosure.absoluteUpperBound <= tolerance else {
                throw NonlinearPhysicalResidualError.uncertifiedResidual(row: index,
                    upperBound: enclosure.absoluteUpperBound, tolerance: tolerance)
            }
        }
    }

    private func buildInitialGuess(
        plan: ExecutionPlan,
        variableMap: [MNAVariable: Int],
        dimension: Int
    ) throws -> [Double] {
        var guess = [Double](repeating: 0.0, count: dimension)

        for (node, value) in nodeInitialGuess {
            guard value.isFinite else {
                throw AnalysisError.invalidConfiguration(
                    "nodeInitialGuess for node \(node.id) must be finite."
                )
            }
            if node == plan.ir.groundNode {
                guard value == 0 else {
                    throw AnalysisError.invalidConfiguration(
                        "ground node initial guess must be zero."
                    )
                }
                continue
            }
            guard let index = variableMap[.nodeVoltage(node)] else {
                throw AnalysisError.invalidConfiguration(
                    "nodeInitialGuess references node \(node.id), which is not in the execution plan."
                )
            }
            guess[index] = value
        }

        return guess
    }
}
