import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Foundation

/// Transient (time-domain) analysis.
///
/// Simulates the circuit from time 0 to `config.stopTime` using
/// adaptive timestep control with local truncation error (LTE)
/// estimation. The algorithm:
///
/// 1. Find the DC operating point for `t = 0`.
/// 2. Start with Backward Euler for the first step.
/// 3. For each timestep:
///    a. Constrain `dt` by `maxTimeStep` and breakpoints.
///    b. Run Newton-Raphson with `stampTransient`.
///    c. If Newton fails, reduce `dt` and retry.
///    d. Estimate LTE; if too large, reduce `dt` and reject the step.
///    e. Save the accepted solution.
///    f. Compute the optimal next `dt` from LTE.
///    g. Switch to Trapezoidal after the first accepted step.
/// 4. Return all saved time points and solutions.
public struct TransientAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?

    public typealias Result = TransientResult
    private static let maximumReservedTimePoints = 1_000_000

    /// Transient-specific configuration (stop time, timestep limits, LTE tolerance).
    public let config: TransientConfig

    /// Convergence configuration for the Newton-Raphson solver at each timestep.
    public let convergenceConfig: ConvergenceConfig

    /// Called after each accepted timestep with the accepted time and solution.
    public let onStepAccepted: (@Sendable (Double, [Double]) -> Void)?

    public init(
        config: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig(),
        onStepAccepted: (@Sendable (Double, [Double]) -> Void)? = nil
    ) {
        self.config = config
        self.convergenceConfig = convergenceConfig
        self.onStepAccepted = onStepAccepted
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> TransientResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .tran,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            try config.validate()
            try validate(convergenceConfig: convergenceConfig)

            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            let executionLimits = try config.requiredExecutionLimits()
            let budget: TransientExecutionBudget
            if let executionBudget {
                guard executionBudget.limits == executionLimits, executionBudget.dimension == dim else {
                    throw AnalysisError.invalidConfiguration("Injected transient budget does not match the circuit and limits")
                }
                budget = executionBudget
            } else {
                budget = try TransientExecutionBudget(limits: executionLimits, dimension: dim,
                    nonZeroCount: plan.matrixStructure.nonZeroCount, deviceCount: devices.count)
            }
            try budget.admitSavedPoint(accepted: false)
            // Extract branch current indices for LTE normalization
            let branchCurrentIndices: Set<Int> = Set(
                variableMap.compactMap { key, value in
                    if case .branchCurrent = key { return value }
                    return nil
                }
            )



            // Phase 1: Initial solution for t = 0
            let initialSolution: [Double]
            if config.useInitialConditions {
                // UIC mode: skip DC, build initial solution from device ICs
                initialSolution = try Self.buildUICInitialSolution(
                    devices: devices,
                    plan: plan,
                    variableMap: variableMap,
                    dimension: dim,
                    nodeVoltages: config.initialNodeVoltages
                )
            } else {
                // Standard mode: DC operating point
                var dcAnalysis = DCAnalysis(
                    config: convergenceConfig,
                    nodeInitialGuess: config.nodeVoltageGuesses
                )
                dcAnalysis.executionBudget = budget
                let dcResult = try await dcAnalysis.run(
                    plan: plan,
                    devices: devices,
                    solver: solver,
                    observer: observer,
                    cancellation: cancellation
                )
                initialSolution = dcResult.variables
            }

            if let index = initialSolution.firstIndex(where: { !$0.isFinite }) {
                throw AnalysisError.nonFiniteSolution(iteration: 0, variableIndex: index, value: initialSolution[index])
            }
            var acquiredSessions: [any TransientSessionDevice] = []
            defer { for device in acquiredSessions.reversed() { device.endTransientSession() } }
            let initialState = SolutionState(variables: initialSolution, variableMap: variableMap)
            for device in devices {
                if let session = device as? any TransientSessionDevice {
                    try session.beginTransientSession(initialState: initialState)
                    acquiredSessions.append(session)
                }
            }

            // Initialize state
            var currentTime: Double = 0.0

            // 3-buffer rotation: avoids allocation/deallocation per timestep.
            // currentBuf/previousBuf/twoPreviousBuf are swapped (O(1)) instead
            // of copied (O(n)) when advancing timesteps.
            var currentBuf = initialSolution
            var previousBuf = [Double](repeating: 0, count: dim)
            var twoPreviousBuf = [Double](repeating: 0, count: dim)
            var newtonSolutionBuf = [Double](repeating: 0, count: dim)
            var hasTwoPrevious = false
            // Initialize previousBuf to initialSolution
            for i in 0..<dim { previousBuf[i] = initialSolution[i] }

            // Optical state buffers (mirroring electrical buffer rotation)
            let evaluator = OpticalNetworkEvaluator()
            let opticalNodeCount = plan.opticalNetwork?.opticalNodeCount ?? 0
            var currentOpticalState = OpticalState(nodeCount: opticalNodeCount)

            // Saved results (pre-allocate estimated capacity)
            let initialDt = try config.effectiveInitialTimeStep()
            let estimatedSteps = min(executionLimits.maximumSavedScalars / (dim + 1),
                executionLimits.maximumAcceptedSteps,
                Self.estimatedPointCapacity(
                stopTime: config.stopTime,
                initialTimeStep: initialDt
            ))
            var timePoints: [Double] = [0.0]
            timePoints.reserveCapacity(estimatedSteps)
            var solutionTrace = try SolutionTrace(variableCount: dim, estimatedPointCapacity: estimatedSteps)
            try currentBuf.withUnsafeBufferPointer { try solutionTrace.append($0) }

            // Timestep control
            var dt = initialDt
            var previousDt: Double? = nil
            var method = config.initialMethod
            var acceptedSteps = 0
            var rejectedSteps = 0

            // Breakpoint management: collect from device waveforms
            var breakpointMgr = BreakpointManager()
            let breakpointInterval = 0.0...config.stopTime
            var deviceMaximumTimeStep = Double.infinity
            var breakpointCount = 0
            for device in devices {
                if let constrainedDevice = device as? any TransientTimeStepConstraintDevice {
                    guard constrainedDevice.maximumTransientTimeStep.isFinite,
                          constrainedDevice.maximumTransientTimeStep > 0 else {
                        throw TransientExecutionError.invalidTimeStep(constrainedDevice.maximumTransientTimeStep)
                    }
                    deviceMaximumTimeStep = min(
                        deviceMaximumTimeStep,
                        constrainedDevice.maximumTransientTimeStep
                    )
                }
                let remaining = executionLimits.maximumBreakpoints - breakpointCount
                let deviceBreakpoints = try device.breakpoints(in: breakpointInterval, maximumCount: remaining)
                guard deviceBreakpoints.count <= remaining,
                      deviceBreakpoints.allSatisfy({ $0.isFinite && breakpointInterval.contains($0) }) else {
                    throw AnalysisError.invalidConfiguration("Device returned invalid or excess breakpoints")
                }
                breakpointCount += deviceBreakpoints.count
                if !deviceBreakpoints.isEmpty {
                    breakpointMgr.addBreakpoints(deviceBreakpoints)
                }
            }

            // LTE estimator
            let lteEstimator = LTEEstimator()

            // Allocate working storage
            var matrix = SparseMatrix(structure: plan.matrixStructure)
            var rhs = [Double](repeating: 0, count: dim)
            var mutableSolver = solver

            // Phase 2: Time-stepping loop
            while currentTime < config.stopTime {
                if cancellation.isCancelled || Task.isCancelled {
                    throw AnalysisError.cancelled
                }

                // Do not overshoot stopTime
                if currentTime + dt > config.stopTime {
                    dt = config.stopTime - currentTime
                }

                // Constrain by maximum timestep
                dt = min(dt, config.maxTimeStep, deviceMaximumTimeStep)

                // Constrain by breakpoints
                dt = breakpointMgr.constrainTimeStep(
                    currentTime: currentTime,
                    proposedStep: dt
                )

                // Guard against zero or negative timestep
                try Self.validateAdvance(time: currentTime, step: dt)
                if dt < config.minTimeStep, currentTime + dt != config.stopTime,
                   !breakpointMgr.isAtBreakpoint(currentTime + dt) {
                    throw AnalysisError.timestepTooSmall(dt)
                }

                // Attempt Newton-Raphson for this timestep
                var stepAccepted = false
                var reductions = 0

                while !stepAccepted && reductions <= config.maxTimeStepReductions {
                    if cancellation.isCancelled || Task.isCancelled {
                        throw AnalysisError.cancelled
                    }

                    try Self.validateAdvance(time: currentTime, step: dt)
                    let currentIntegration = IntegrationState(
                        method: method,
                        timeStep: dt,
                        currentTime: currentTime + dt,
                        previousTimeStep: previousDt
                    )

                    // Newton-Raphson solve
                    var nr = NewtonRaphsonSolver(config: convergenceConfig)
                    nr.executionBudget = budget
                    var newtonIterations: Int

                    do {
                        newtonIterations = try await nr.solve(
                            initialGuess: currentBuf,
                            solution: &newtonSolutionBuf,
                            matrix: &matrix,
                            rhs: &rhs,
                            devices: devices,
                            variableMap: variableMap,
                            solver: &mutableSolver,
                            stampFunction: { stamper, state in
                                let transientState = SolutionState(
                                    variables: state.variables,
                                    previousVariables: currentBuf,
                                    twoPreviousVariables: previousBuf,
                                    variableMap: variableMap
                                )
                                // Evaluate optical network at each NR iteration
                                if let graph = plan.opticalNetwork {
                                    currentOpticalState = evaluator.evaluate(
                                        graph: graph,
                                        devices: devices,
                                        electricalState: transientState,
                                        previousOpticalState: currentOpticalState
                                    )
                                }
                                for device in devices {
                                    if let optoDevice = device as? OptoelectronicDevice {
                                        optoDevice.stampTransient(
                                            into: &stamper,
                                            state: transientState,
                                            opticalState: currentOpticalState,
                                            integration: currentIntegration
                                        )
                                    } else {
                                        try device.stampTransient(
                                            into: &stamper,
                                            state: transientState,
                                            integration: currentIntegration
                                        )
                                    }
                                }
                            },
                            observer: observer,
                            analysisID: analysisID,
                            cancellation: cancellation
                        )
                    } catch let error as AnalysisError {
                        guard case .convergenceFailure = error else { throw error }
                        // Newton failed: try GMIN stepping before reducing timestep
                        reductions = try TransientExecutionBudget.add(reductions, 1, "timeStepReductions")

                        if reductions == config.gminSteppingThreshold {
                            do {
                                let gminResult = try await tryGminStepping(
                                    currentBuf: currentBuf,
                                    previousBuf: previousBuf,
                                    solution: &newtonSolutionBuf,
                                    opticalState: &currentOpticalState,
                                    evaluator: evaluator,
                                    opticalNetwork: plan.opticalNetwork,
                                    matrix: &matrix,
                                    rhs: &rhs,
                                    devices: devices,
                                    variableMap: variableMap,
                                    solver: &mutableSolver,
                                    integration: currentIntegration,
                                    observer: observer,
                                    analysisID: analysisID,
                                    cancellation: cancellation,
                                    executionBudget: budget
                                )
                                // GMIN stepping succeeded — use this solution
                                newtonIterations = gminResult
                            } catch let error as AnalysisError {
                                guard case .convergenceFailure = error else { throw error }
                                // GMIN stepping failed — fall through to timestep reduction
                                let oldDt = dt
                                dt *= config.shrinkFactor
                                try budget.rejectStep()
                                rejectedSteps = try TransientExecutionBudget.add(rejectedSteps, 1, "rejectedSteps")

                                await observer?.emit(.timeStepRejected(TimeStepRejectInfo(
                                    id: analysisID,
                                    time: currentTime,
                                    rejectedStep: oldDt,
                                    newStep: dt,
                                    reason: "Newton-Raphson + GMIN stepping failure: \(error)"
                                )))

                                if dt < config.minTimeStep {
                                    throw AnalysisError.timestepTooSmall(dt)
                                }
                                continue
                            }
                        } else {
                            // Normal timestep reduction
                            let oldDt = dt
                            dt *= config.shrinkFactor
                            try budget.rejectStep()
                            rejectedSteps = try TransientExecutionBudget.add(rejectedSteps, 1, "rejectedSteps")

                            await observer?.emit(.timeStepRejected(TimeStepRejectInfo(
                                id: analysisID,
                                time: currentTime,
                                rejectedStep: oldDt,
                                newStep: dt,
                                reason: "Newton-Raphson convergence failure"
                            )))

                            if dt < config.minTimeStep {
                                throw AnalysisError.timestepTooSmall(dt)
                            }
                            continue
                        }
                    }

                    // LTE check (skip for the very first step)
                    if acceptedSteps > 0 {
                        let lte = lteEstimator.estimate(
                            current: newtonSolutionBuf,
                            previous: currentBuf,
                            twoPrevious: hasTwoPrevious ? previousBuf : nil,
                            timeStep: dt,
                            previousTimeStep: previousDt,
                            method: method,
                            branchCurrentIndices: branchCurrentIndices,
                            reltol: convergenceConfig.reltol,
                            vntol: convergenceConfig.vntol,
                            abstol: convergenceConfig.abstol
                        )

                        guard lte.isFinite else { throw TransientExecutionError.nonFiniteLTE(lte) }
                        if lte > config.lteTolerance {
                            // LTE too large: reduce timestep and reject
                            let optDt = lteEstimator.optimalTimeStep(
                                currentStep: dt,
                                lte: lte,
                                tolerance: config.lteTolerance,
                                method: method
                            )
                            let oldDt = dt
                            guard dt > config.minTimeStep else { throw AnalysisError.timestepTooSmall(dt) }
                            dt = max(optDt, config.minTimeStep)
                            reductions = try TransientExecutionBudget.add(reductions, 1, "timeStepReductions")
                            try budget.rejectStep()
                            rejectedSteps = try TransientExecutionBudget.add(rejectedSteps, 1, "rejectedSteps")

                            await observer?.emit(.timeStepRejected(TimeStepRejectInfo(
                                id: analysisID,
                                time: currentTime,
                                rejectedStep: oldDt,
                                newStep: dt,
                                reason: "LTE exceeded tolerance (\(lte) > \(config.lteTolerance))"
                            )))

                            if dt < config.minTimeStep {
                                throw AnalysisError.timestepTooSmall(dt)
                            }
                            continue
                        }

                        // Compute optimal next dt from LTE
                        let optimalNext = lteEstimator.optimalTimeStep(
                            currentStep: dt,
                            lte: lte,
                            tolerance: config.lteTolerance,
                            method: method
                        )

                        // Update dt for the next step (will be clamped by maxTimeStep later)
                        let nextDt = min(optimalNext, config.maxTimeStep)

                        try budget.admitSavedPoint(accepted: true)
                        // Accept this step — O(1) buffer rotation
                        stepAccepted = true
                        swap(&twoPreviousBuf, &previousBuf)
                        swap(&previousBuf, &currentBuf)
                        swap(&currentBuf, &newtonSolutionBuf)
                        hasTwoPrevious = true

                        // Commit transient device state for trapezoidal companion models.
                        // After buffer rotation: currentBuf=V_n, previousBuf=V_{n-1}.
                        let commitState = SolutionState(
                            variables: currentBuf,
                            previousVariables: previousBuf,
                            variableMap: variableMap
                        )
                        let commitIntegration = IntegrationState(
                            method: method,
                            timeStep: dt,
                            currentTime: currentTime + dt,
                            previousTimeStep: previousDt
                        )
                        for device in devices {
                            if let committingDevice = device as? any TransientStateCommittingDevice {
                                try committingDevice.commitTransientStep(state: commitState, integration: commitIntegration)
                            }
                        }

                        previousDt = dt
                        currentTime += dt
                        acceptedSteps += 1

                        // Save the time point
                        timePoints.append(currentTime)
                        try currentBuf.withUnsafeBufferPointer { try solutionTrace.append($0) }
                        onStepAccepted?(currentTime, currentBuf)

                        await observer?.emit(.timeStepCompleted(TimeStepInfo(
                            id: analysisID,
                            time: currentTime,
                            timeStep: dt,
                            iterations: newtonIterations,
                            lte: lte
                        )))

                        // Emit progress
                        let fraction = min(currentTime / config.stopTime, 1.0)
                        await observer?.emit(.progressUpdate(try ProgressInfo(
                            id: analysisID,
                            fraction: fraction,
                            message: "Transient: t = \(currentTime) s"
                        )))

                        // If we landed on a breakpoint, reset integration state
                        // to avoid LTE artifacts from the 3-point formula spanning
                        // across a waveform discontinuity.
                        if breakpointMgr.isAtBreakpoint(currentTime) {
                            hasTwoPrevious = false
                            method = .backwardEuler
                        } else if method == .backwardEuler && hasTwoPrevious {
                            // Restore trapezoidal after completing one backward Euler
                            // step past the breakpoint (standard SPICE approach).
                            method = .trapezoidal
                        }

                        // Update dt for next iteration
                        dt = nextDt
                    } else {
                        try budget.admitSavedPoint(accepted: true)
                        // First step: no LTE check, just accept — O(1) buffer rotation
                        stepAccepted = true
                        swap(&previousBuf, &currentBuf)
                        swap(&currentBuf, &newtonSolutionBuf)
                        // hasTwoPrevious stays false

                        // Commit transient device state (first step is always BE).
                        let commitState = SolutionState(
                            variables: currentBuf,
                            previousVariables: previousBuf,
                            variableMap: variableMap
                        )
                        let commitIntegration = IntegrationState(
                            method: method,
                            timeStep: dt,
                            currentTime: currentTime + dt,
                            previousTimeStep: previousDt
                        )
                        for device in devices {
                            if let committingDevice = device as? any TransientStateCommittingDevice {
                                try committingDevice.commitTransientStep(state: commitState, integration: commitIntegration)
                            }
                        }

                        previousDt = dt
                        currentTime += dt
                        acceptedSteps += 1

                        timePoints.append(currentTime)
                        try currentBuf.withUnsafeBufferPointer { try solutionTrace.append($0) }
                        onStepAccepted?(currentTime, currentBuf)

                        await observer?.emit(.timeStepCompleted(TimeStepInfo(
                            id: analysisID,
                            time: currentTime,
                            timeStep: dt,
                            iterations: newtonIterations,
                            lte: 0.0
                        )))

                        // Switch to Trapezoidal for subsequent steps
                        // (unless we landed on a breakpoint, in which case
                        // stay on backward Euler to avoid LTE artifacts)
                        if !breakpointMgr.isAtBreakpoint(currentTime) {
                            method = .trapezoidal
                        }
                    }
                }

                if !stepAccepted {
                    throw AnalysisError.timestepTooSmall(dt)
                }
            }

            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            let result = try TransientResult(
                timePoints: timePoints,
                solutionTrace: solutionTrace,
                variableMap: variableMap,
                timeSteps: acceptedSteps,
                rejectedSteps: rejectedSteps,
                executionStatistics: budget.statistics
            )

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .tran,
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
                type: .tran,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    /// Attempts GMIN stepping at the current timestep to find a converged solution.
    ///
    /// Progressively reduces GMIN from a large value to the target, using each
    /// converged solution as the initial guess for the next step — the same
    /// algorithm as DC GMIN stepping, but applied to the transient stamp.
    ///
    /// - Returns: The converged solution and iteration count, or `nil` if all steps failed.
    private func tryGminStepping(
        currentBuf: [Double],
        previousBuf: [Double],
        solution: inout [Double],
        opticalState: inout OpticalState,
        evaluator: OpticalNetworkEvaluator,
        opticalNetwork: OpticalNetworkGraph?,
        matrix: inout SparseMatrix,
        rhs: inout [Double],
        devices: [any BoundDevice],
        variableMap: [MNAVariable: Int],
        solver: inout any LinearSolver,
        integration: IntegrationState,
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken,
        executionBudget: TransientExecutionBudget
    ) async throws -> Int {
        var guess = [Double](repeating: 0.0, count: currentBuf.count)
        currentBuf.withUnsafeBufferPointer { src in
            guess.withUnsafeMutableBufferPointer { dst in
                if let srcBase = src.baseAddress, let dstBase = dst.baseAddress {
                    dstBase.update(from: srcBase, count: src.count)
                }
            }
        }
        if solution.count != currentBuf.count {
            solution = [Double](repeating: 0.0, count: currentBuf.count)
        }
        var totalIterations = 0

        for gmin in config.gminStepping.lazyValues() {
            var stepConfig = convergenceConfig
            stepConfig.gmin = gmin

            var nr = NewtonRaphsonSolver(config: stepConfig)
            nr.executionBudget = executionBudget
            do {
                let iterations = try await nr.solve(
                    initialGuess: guess,
                    solution: &solution,
                    matrix: &matrix,
                    rhs: &rhs,
                    devices: devices,
                    variableMap: variableMap,
                    solver: &solver,
                    stampFunction: { stamper, state in
                        let transientState = SolutionState(
                            variables: state.variables,
                            previousVariables: currentBuf,
                            twoPreviousVariables: previousBuf,
                            variableMap: variableMap
                        )
                        // Evaluate optical network
                        if let graph = opticalNetwork {
                            opticalState = evaluator.evaluate(
                                graph: graph,
                                devices: devices,
                                electricalState: transientState,
                                previousOpticalState: opticalState
                            )
                        }
                        for device in devices {
                            if let optoDevice = device as? OptoelectronicDevice {
                                optoDevice.stampTransient(
                                    into: &stamper,
                                    state: transientState,
                                    opticalState: opticalState,
                                    integration: integration
                                )
                            } else {
                                try device.stampTransient(
                                    into: &stamper,
                                    state: transientState,
                                    integration: integration
                                )
                            }
                        }
                    },
                    observer: observer,
                    analysisID: analysisID,
                    cancellation: cancellation
                )
                swap(&guess, &solution)
                totalIterations += iterations
            } catch {
                throw error
            }
        }

        swap(&guess, &solution)
        return totalIterations
    }

    /// Builds the initial solution vector from device initial conditions (UIC mode).
    ///
    /// Starts from a zero vector and applies each device's stored initial
    /// voltage or current to the corresponding matrix indices.
    private static func buildUICInitialSolution(
        devices: [any BoundDevice],
        plan: ExecutionPlan,
        variableMap: [MNAVariable: Int],
        dimension: Int,
        nodeVoltages: [Node: Double]
    ) throws -> [Double] {
        var solution = [Double](repeating: 0.0, count: dimension)

        for device in devices {
            if let terminalDevice = device as? any TerminalInitialConditionDevice {
                for (node, voltage) in terminalDevice.initialNodeVoltages {
                    if let index = variableMap[.nodeVoltage(node)] { solution[index] = voltage }
                }
            }
            if let vicDevice = device as? VoltageInitialConditionDevice,
               vicDevice.hasInitialCondition {
                let posNode = vicDevice.positiveNode
                let negNode = vicDevice.negativeNode
                // Set absolute node voltage so that V(pos) - V(neg) = initialVoltage.
                // When neg is ground (no variable), posIdx is set directly.
                // When pos is ground (no variable), negIdx is set to -initialVoltage.
                // When both are non-ground, only posIdx is set (negIdx stays at its
                // current value, typically 0); this avoids doubling the differential.
                if let posIdx = variableMap[.nodeVoltage(posNode)] {
                    solution[posIdx] = vicDevice.initialVoltage
                } else if let negIdx = variableMap[.nodeVoltage(negNode)] {
                    solution[negIdx] = -vicDevice.initialVoltage
                }
            }
            if let cicDevice = device as? CurrentInitialConditionDevice,
               cicDevice.hasInitialCondition {
                let branch = cicDevice.deviceBranch
                if let branchIdx = variableMap[.branchCurrent(branch)] {
                    solution[branchIdx] = cicDevice.initialCurrent
                }
            }
        }

        for (node, voltage) in nodeVoltages {
            guard voltage.isFinite else {
                throw AnalysisError.invalidConfiguration(
                    "initialNodeVoltages for node \(node.id) must be finite."
                )
            }
            if node == plan.ir.groundNode {
                guard voltage == 0 else {
                    throw AnalysisError.invalidConfiguration(
                        "ground node initial voltage must be zero."
                    )
                }
                continue
            }
            guard let nodeIdx = variableMap[.nodeVoltage(node)] else {
                throw AnalysisError.invalidConfiguration(
                    "initialNodeVoltages references node \(node.id), which is not in the execution plan."
                )
            }
            solution[nodeIdx] = voltage
        }

        return solution
    }

    static func validateAdvance(time: Double, step: Double) throws {
        guard step.isFinite, step > 0 else { throw TransientExecutionError.invalidTimeStep(step) }
        guard (time + step).isFinite, time + step > time else {
            throw TransientExecutionError.nonProgressingTime(time: time, timeStep: step)
        }
    }

    static func estimatedPointCapacity(stopTime: Double, initialTimeStep: Double) -> Int {
        let rawEstimate = stopTime / initialTimeStep
        guard rawEstimate.isFinite, rawEstimate > 0 else {
            return 64
        }
        let boundedEstimate = min(rawEstimate.rounded(.up), Double(maximumReservedTimePoints))
        return max(Int(boundedEstimate), 64)
    }

    private func validate(convergenceConfig: ConvergenceConfig) throws {
        try validatePositiveFinite(convergenceConfig.abstol, name: "abstol")
        try validatePositiveFinite(convergenceConfig.reltol, name: "reltol")
        try validatePositiveFinite(convergenceConfig.vntol, name: "vntol")
        try validatePositiveFinite(convergenceConfig.opticalPowerTolerance, name: "opticalPowerTolerance")

        guard convergenceConfig.maxIterations > 0 else {
            throw AnalysisError.invalidConfiguration(
                "maxIterations must be greater than zero."
            )
        }
        guard convergenceConfig.gmin >= 0, convergenceConfig.gmin.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "gmin must be finite and greater than or equal to zero."
            )
        }
        guard convergenceConfig.minDamping > 0,
              convergenceConfig.minDamping <= 1,
              convergenceConfig.minDamping.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "minDamping must be finite and in the interval (0, 1]."
            )
        }
    }

    private func validatePositiveFinite(_ value: Double, name: String) throws {
        guard value > 0, value.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "\(name) must be finite and greater than zero."
            )
        }
    }
}
