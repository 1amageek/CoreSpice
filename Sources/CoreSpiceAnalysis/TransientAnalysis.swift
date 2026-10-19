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
/// 2. Validate Backward Euler startup using independent quarter, half and full trials.
/// 3. For each timestep:
///    a. Constrain `dt` by `maxTimeStep` and breakpoints.
///    b. Run Newton-Raphson with `stampTransient`.
///    c. If Newton fails, reduce `dt` and retry.
///    d. Estimate LTE; if too large, reduce `dt` and reject the step.
///    e. Save the accepted solution.
///    f. Compute the optimal next `dt` from LTE.
///    g. Use the preferred method after three smooth accepted samples.
/// 4. Return all saved time points and solutions.
public struct TransientAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?

    public typealias Result = TransientResult
    private static let maximumReservedTimePoints = 1_000_000

    /// Transient-specific configuration (stop time, timestep limits, LTE tolerance).
    public let config: TransientConfig

    /// Convergence configuration for the Newton-Raphson solver at each timestep.
    public let equationPolicy: DCEquationPolicy?
    public let operatingPointValidator: (any DCPhysicalResidualValidating)?
    public let physicalResidualEncloser: (any TransientPhysicalResidualEnclosing)?
    public let physicalResidualValidator: (any TransientPhysicalResidualValidating)?
    public let completionFinalizer: (any AnalysisCompletionFinalizing)?
    /// Caller-proven coordinates requiring integration error control; nil preserves the existing selection.
    public let errorControlVariables: Set<MNAVariable>?
    public let convergenceConfig: ConvergenceConfig

    /// Called after each accepted timestep with the accepted time and solution.
    public let onStepAccepted: (@Sendable (Double, [Double]) -> Void)?

    public init(
        config: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig(),
        onStepAccepted: (@Sendable (Double, [Double]) -> Void)? = nil,
        equationPolicy: DCEquationPolicy? = nil,
        operatingPointValidator: (any DCPhysicalResidualValidating)? = nil,
        physicalResidualValidator: (any TransientPhysicalResidualValidating)? = nil,
        completionFinalizer: (any AnalysisCompletionFinalizing)? = nil,
        errorControlVariables: Set<MNAVariable>? = nil,
        physicalResidualEncloser: (any TransientPhysicalResidualEnclosing)? = nil
    ) {
        self.physicalResidualEncloser = physicalResidualEncloser
        self.errorControlVariables = errorControlVariables
        self.equationPolicy = equationPolicy
        self.operatingPointValidator = operatingPointValidator
        self.physicalResidualValidator = physicalResidualValidator
        self.completionFinalizer = completionFinalizer
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
        let compensated = physicalResidualEncloser != nil

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .tran,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            try config.validate()
            if compensated {
                guard equationPolicy != nil, !(physicalResidualValidator is any TransientPhysicalResidualEvaluating),
                      !devices.contains(where: { $0 is any VoltageLimitingDevice }) else {
                    throw NumericalStateError.incompatiblePrecisionConfiguration
                }
            }
            if let errorControlVariables {
                for variable in errorControlVariables where variableMap[variable] == nil {
                    throw TransientExecutionError.unknownErrorControlVariable(variable)
                }
            }
            try equationPolicy?.validate(dimension: dim, variableMap: variableMap, config: convergenceConfig)
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
            if compensated { try budget.admitSavedScalars(dim) }
            let precisionBytes = compensated ? try TransientExecutionBudget.multiply(dim, 8 * MemoryLayout<Double>.stride, "precision scratch bytes") : 0
            let precisionStorage = try resultStorage?.reserveTemporaryBytes(UInt64(precisionBytes))
            defer { withExtendedLifetime(precisionStorage) {} }
            // Extract branch current indices for LTE normalization
            let branchCurrentIndices: Set<Int> = Set(
                variableMap.compactMap { key, value in
                    if case .branchCurrent = key { return value }
                    return nil
                }
            )



            // Phase 1: Initial solution for t = 0
            let initialSolution: [Double]
            let operatingPoint: DCResult?
            if config.useInitialConditions {
                operatingPoint = nil
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
                    nodeInitialGuess: config.nodeVoltageGuesses,
                    equationPolicy: equationPolicy,
                    physicalResidualValidator: operatingPointValidator,
                    precisionMode: compensated ? .automatic : .binary64
                )
                dcAnalysis.executionBudget = budget
                dcAnalysis.resultStorage = resultStorage
                let dcResult = try await dcAnalysis.run(
                    plan: plan,
                    devices: devices,
                    solver: solver,
                    observer: observer,
                    cancellation: cancellation
                )
                try budget.admitSavedScalars(dcResult.variables.count)
                operatingPoint = dcResult
                initialSolution = dcResult.variables
            }

            if let index = initialSolution.firstIndex(where: { !$0.isFinite }) {
                throw AnalysisError.nonFiniteSolution(iteration: 0, variableIndex: index, value: initialSolution[index])
            }
            var acquiredSessions: [any TransientSessionDevice] = []
            defer { for device in acquiredSessions.reversed() { device.endTransientSession() } }
            var currentLow = compensated ? (operatingPoint?.variableLowComponents ?? [Double](repeating: 0, count: dim)) : []
            do {
                let initialState = SolutionState(variables: initialSolution, variableMap: variableMap,
                    variableLowComponents: compensated ? currentLow : nil)
                for device in devices {
                    if let session = device as? any TransientSessionDevice {
                        try session.beginTransientSession(initialState: initialState,
                            initialization: config.useInitialConditions ? .initialConditions : .operatingPoint)
                        acquiredSessions.append(session)
                    }
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
            let quarterStorage = try resultStorage?.reserveTemporaryBytes(UInt64(dim) * UInt64(MemoryLayout<Double>.stride))
            defer { withExtendedLifetime(quarterStorage) {} }
            var quarterSolutionBuf = [Double](repeating: 0, count: dim)
            var previousLow = compensated ? [Double](repeating: 0, count: dim) : []
            var twoPreviousLow = compensated ? [Double](repeating: 0, count: dim) : []
            var newtonSolutionLow = compensated ? [Double](repeating: 0, count: dim) : []
            var quarterSolutionLow = compensated ? [Double](repeating: 0, count: dim) : []
            var smoothHistoryCount = config.useInitialConditions ? 0 : 1
            let variableTolerances = equationPolicy?.rows.map(\.variableAbsoluteTolerance)
            let excludedLTEIndices: Set<Int>
            if let errorControlVariables {
                var excluded: Set<Int> = []
                excluded.reserveCapacity(dim)
                for (variable, index) in variableMap where !errorControlVariables.contains(variable) {
                    excluded.insert(index)
                }
                excludedLTEIndices = excluded
            } else {
                excludedLTEIndices = equationPolicy == nil ? branchCurrentIndices : Set<Int>()
            }
            let auditScalars = (MemoryLayout<TransientAcceptedStep>.stride + MemoryLayout<Double>.stride - 1) / MemoryLayout<Double>.stride
            let coordinateScalars = try TransientExecutionBudget.multiply(dim, compensated ? 2 : 1, "retained coordinate scalars")
            let retainedPointScalars = try TransientExecutionBudget.add(
                TransientExecutionBudget.add(coordinateScalars, 1, "point scalars"), auditScalars, "point audit scalars")
            let operatingPointScalars = try TransientExecutionBudget.multiply(
                operatingPoint?.variables.count ?? 0, operatingPoint?.variableLowComponents == nil ? 1 : 2,
                "transient represented OP scalars")
            // Initialize previousBuf to initialSolution
            for i in 0..<dim {
                previousBuf[i] = initialSolution[i]
                if compensated { previousLow[i] = currentLow[i] }
            }

            // Optical state buffers (mirroring electrical buffer rotation)
            let evaluator = OpticalNetworkEvaluator()
            let opticalNodeCount = plan.opticalNetwork?.opticalNodeCount ?? 0
            var currentOpticalState = OpticalState(nodeCount: opticalNodeCount)
            var acceptedOpticalState = currentOpticalState

            // Saved results (pre-allocate estimated capacity)
            let initialDt = try config.effectiveInitialTimeStep()
            let estimatedSteps = resultStorage == nil ? min(executionLimits.maximumSavedScalars / retainedPointScalars,
                executionLimits.maximumAcceptedSteps,
                Self.estimatedPointCapacity(
                stopTime: config.stopTime,
                initialTimeStep: initialDt
            )) : 1
            var reservedPointCapacity = estimatedSteps
            try resultStorage?.reserveResultScalars(TransientExecutionBudget.add(
                TransientExecutionBudget.multiply(estimatedSteps, retainedPointScalars, "transient result capacity"),
                operatingPointScalars, "transient OP and result capacity"))
            var integrationRecords: [TransientAcceptedStep] = []
            integrationRecords.reserveCapacity(estimatedSteps)
            var timePoints: [Double] = [0.0]
            timePoints.reserveCapacity(estimatedSteps)
            var solutionTrace = try SolutionTrace(variableCount: dim, estimatedPointCapacity: estimatedSteps)
            try currentBuf.withUnsafeBufferPointer { try solutionTrace.append($0) }
            var solutionLowTrace: SolutionTrace? = compensated ? try SolutionTrace(variableCount: dim, estimatedPointCapacity: estimatedSteps) : nil
            if compensated { try currentLow.withUnsafeBufferPointer { try solutionLowTrace?.append($0) } }

            // Timestep control
            var dt = initialDt
            var previousDt: Double? = nil
            var twoPreviousDt: Double? = nil
            var previousDtLow: Double? = nil
            var twoPreviousDtLow: Double? = nil
            var acceptedSteps = 0
            var rejectedSteps = 0

            // Breakpoint management: collect from device waveforms
            var breakpointMgr = BreakpointManager()
            let breakpointInterval = 0.0...config.stopTime
            var breakpointCount = 0
            for device in devices {
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
                var deviceMaximumTimeStep = Double.infinity
                for device in devices {
                    if let constrained = device as? any TransientTimeStepConstraintDevice {
                        let maximum = constrained.maximumTransientTimeStep
                        guard maximum > 0, !maximum.isNaN else { throw TransientExecutionError.invalidTimeStep(maximum) }
                        deviceMaximumTimeStep = min(deviceMaximumTimeStep, maximum)
                    }
                }
                dt = min(dt, config.maxTimeStep, deviceMaximumTimeStep)

                let remaining = config.stopTime - currentTime
                if remaining > dt, remaining - dt < config.minTimeStep {
                    let approach = BreakpointManager.constrainApproach(distance: remaining, proposedStep: dt)
                    if approach >= config.minTimeStep, approach <= dt { dt = approach }
                }

                // Constrain by breakpoints
                let proposedDt = dt
                dt = breakpointMgr.constrainTimeStep(
                    currentTime: currentTime,
                    proposedStep: dt
                )
                // Optional half-distance approaches must not invalidate an admitted proposal.
                if proposedDt >= config.minTimeStep, dt < config.minTimeStep,
                   currentTime + dt != config.stopTime,
                   !breakpointMgr.isAtBreakpoint(currentTime + dt) {
                    dt = proposedDt
                }

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
                    let bootstrapping = smoothHistoryCount < 3
                    let quarterTime = currentTime + dt / 4
                    let halfTime = currentTime + dt / 2
                    var embeddedBootstrap = bootstrapping && acceptedSteps > 0 && !(currentTime < quarterTime
                        && quarterTime < halfTime && halfTime < currentTime + dt)
                    let method: IntegrationMethod = bootstrapping ? .backwardEuler : config.preferredMethod
                    let currentIntegration = try integrationState(method: method, acceptedTime: currentTime,
                        candidateTime: currentTime + dt, proposedStep: dt, previousTimeStep: previousDt,
                        previousLow: previousDtLow)
                    let allowGmin = try TransientExecutionBudget.add(reductions, 1, "recovery threshold") == config.gminSteppingThreshold
                    var newtonIterations = 0
                    do {
                        if bootstrapping && !embeddedBootstrap {
                            let subdivisionStartIterations = budget.statistics.newtonIterations
                            do {
                                // The invalid oldest-history slot is scratch until three accepted samples exist.
                                let half = dt / 2
                                let quarter = dt / 4
                                try Self.validateAdvance(time: currentTime, step: quarter)
                                try Self.validateAdvance(time: currentTime, step: half)
                                newtonIterations = try await solveTransientTrial(
                                    currentBuf: currentBuf, previousBuf: previousBuf, solution: &quarterSolutionBuf,
                                    currentLow: currentLow, previousLow: previousLow, solutionLow: &quarterSolutionLow,
                                    acceptedOpticalState: acceptedOpticalState, opticalState: &currentOpticalState,
                                    evaluator: evaluator, opticalNetwork: plan.opticalNetwork, matrix: &matrix, rhs: &rhs,
                                    devices: devices, variableMap: variableMap, solver: &mutableSolver,
                                    integration: try integrationState(method: .backwardEuler, acceptedTime: currentTime,
                                        candidateTime: currentTime + quarter, proposedStep: quarter,
                                        previousTimeStep: previousDt, previousLow: previousDtLow),
                                    allowGmin: allowGmin, observer: observer, analysisID: analysisID,
                                    cancellation: cancellation, executionBudget: budget)
                                let halfIterations = try await solveTransientTrial(
                                    currentBuf: currentBuf, previousBuf: previousBuf, solution: &twoPreviousBuf,
                                    currentLow: currentLow, previousLow: previousLow, solutionLow: &twoPreviousLow,
                                    acceptedOpticalState: acceptedOpticalState, opticalState: &currentOpticalState,
                                    evaluator: evaluator, opticalNetwork: plan.opticalNetwork, matrix: &matrix, rhs: &rhs,
                                    devices: devices, variableMap: variableMap, solver: &mutableSolver,
                                    integration: try integrationState(method: .backwardEuler, acceptedTime: currentTime,
                                        candidateTime: currentTime + half, proposedStep: half,
                                        previousTimeStep: previousDt, previousLow: previousDtLow),
                                    allowGmin: allowGmin, observer: observer, analysisID: analysisID,
                                    cancellation: cancellation, executionBudget: budget)
                                newtonIterations = try TransientExecutionBudget.add(newtonIterations, halfIterations, "bootstrap iterations")
                            } catch let error as AnalysisError {
                                guard case .convergenceFailure = error, acceptedSteps > 0 else { throw error }
                                newtonIterations = budget.statistics.newtonIterations - subdivisionStartIterations
                                try budget.rejectStep()
                                rejectedSteps = try TransientExecutionBudget.add(rejectedSteps, 1, "rejectedSteps")
                                await observer?.emit(.timeStepRejected(TimeStepRejectInfo(id: analysisID,
                                    time: currentTime, rejectedStep: dt, newStep: dt,
                                    reason: "Bootstrap subdivision convergence failure; using same-interval BE/TR estimate")))
                                embeddedBootstrap = true
                            }
                        }
                        if embeddedBootstrap {
                            // Both methods use the same accepted derivative history and full interval.
                            let referenceIterations = try await solveTransientTrial(
                                currentBuf: currentBuf, previousBuf: previousBuf, solution: &quarterSolutionBuf,
                                    currentLow: currentLow, previousLow: previousLow, solutionLow: &quarterSolutionLow,
                                acceptedOpticalState: acceptedOpticalState, opticalState: &currentOpticalState,
                                evaluator: evaluator, opticalNetwork: plan.opticalNetwork, matrix: &matrix, rhs: &rhs,
                                devices: devices, variableMap: variableMap, solver: &mutableSolver,
                                integration: try integrationState(method: .trapezoidal, acceptedTime: currentTime,
                                    candidateTime: currentTime + dt, proposedStep: dt,
                                    previousTimeStep: previousDt, previousLow: previousDtLow),
                                allowGmin: allowGmin, observer: observer, analysisID: analysisID,
                                cancellation: cancellation, executionBudget: budget)
                            newtonIterations = try TransientExecutionBudget.add(newtonIterations, referenceIterations, "embedded trial iterations")
                        }
                        let fullIterations = try await solveTransientTrial(
                            currentBuf: currentBuf, previousBuf: previousBuf, solution: &newtonSolutionBuf,
                            currentLow: currentLow, previousLow: previousLow, solutionLow: &newtonSolutionLow,
                            acceptedOpticalState: acceptedOpticalState, opticalState: &currentOpticalState,
                            evaluator: evaluator, opticalNetwork: plan.opticalNetwork, matrix: &matrix, rhs: &rhs,
                            devices: devices, variableMap: variableMap, solver: &mutableSolver,
                            integration: currentIntegration, allowGmin: allowGmin, observer: observer,
                            analysisID: analysisID, cancellation: cancellation, executionBudget: budget)
                        newtonIterations = try TransientExecutionBudget.add(newtonIterations, fullIterations, "trial iterations")
                    } catch let error as AnalysisError {
                        guard case .convergenceFailure = error else { throw error }
                        reductions = try TransientExecutionBudget.add(reductions, 1, "timeStepReductions")
                        let oldDt = dt
                        dt *= config.shrinkFactor
                        if oldDt > config.minTimeStep { dt = max(dt, config.minTimeStep) }
                        try budget.rejectStep()
                        rejectedSteps = try TransientExecutionBudget.add(rejectedSteps, 1, "rejectedSteps")
                        await observer?.emit(.timeStepRejected(TimeStepRejectInfo(id: analysisID,
                            time: currentTime, rejectedStep: oldDt, newStep: dt,
                            reason: "Newton-Raphson convergence failure")))
                        if dt < config.minTimeStep { throw AnalysisError.timestepTooSmall(dt) }
                        continue
                    }

                    try budget.chargeWork(TransientExecutionBudget.multiply(dim, compensated ? 2048 : (bootstrapping ? 12 : 20), "LTE vector work"))
                    if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
                    let lte: Double
                    if compensated {
                        lte = try CompensatedLTEEstimator().estimate(
                            current: SolutionState(variables: newtonSolutionBuf, previousVariables: currentBuf,
                                twoPreviousVariables: previousBuf, variableMap: variableMap,
                                variableLowComponents: newtonSolutionLow, previousVariableLowComponents: currentLow,
                                twoPreviousVariableLowComponents: previousLow),
                            threePrevious: twoPreviousBuf, threePreviousLow: twoPreviousLow,
                            half: twoPreviousBuf, halfLow: twoPreviousLow,
                            quarter: quarterSolutionBuf, quarterLow: quarterSolutionLow,
                            integration: currentIntegration, twoPreviousTimeStep: twoPreviousDt,
                            twoPreviousTimeStepLow: twoPreviousDtLow, bootstrap: bootstrapping,
                            embedded: embeddedBootstrap, excluded: excludedLTEIndices,
                            relativeTolerance: convergenceConfig.reltol, absoluteTolerances: variableTolerances,
                            defaultAbsoluteTolerance: convergenceConfig.vntol)
                    } else if embeddedBootstrap {
                        lte = try lteEstimator.estimateEmbedded(current: newtonSolutionBuf, reference: quarterSolutionBuf,
                            branchCurrentIndices: excludedLTEIndices, reltol: convergenceConfig.reltol,
                            vntol: convergenceConfig.vntol, variableAbsoluteTolerances: variableTolerances)
                    } else if bootstrapping {
                        lte = try lteEstimator.estimateBootstrap(current: newtonSolutionBuf, half: twoPreviousBuf,
                            quarter: quarterSolutionBuf, branchCurrentIndices: excludedLTEIndices,
                            reltol: convergenceConfig.reltol, vntol: convergenceConfig.vntol,
                            variableAbsoluteTolerances: variableTolerances)
                    } else {
                        lte = try lteEstimator.estimate(current: newtonSolutionBuf, previous: currentBuf,
                            twoPrevious: previousBuf, timeStep: dt, previousTimeStep: previousDt,
                            method: method, branchCurrentIndices: excludedLTEIndices,
                            reltol: convergenceConfig.reltol, vntol: convergenceConfig.vntol,
                            abstol: convergenceConfig.abstol, earlyExitThreshold: config.lteTolerance,
                            threePrevious: twoPreviousBuf, twoPreviousTimeStep: twoPreviousDt,
                            variableAbsoluteTolerances: variableTolerances)
                    }
                    guard lte.isFinite else { throw TransientExecutionError.nonFiniteLTE(lte) }
                    if lte > config.lteTolerance {
                        let optimal = lteEstimator.optimalTimeStep(currentStep: dt, lte: lte,
                            tolerance: config.lteTolerance, method: method)
                        let oldDt = dt
                        guard dt > config.minTimeStep else { throw AnalysisError.timestepTooSmall(dt) }
                        dt = max(optimal, config.minTimeStep)
                        reductions = try TransientExecutionBudget.add(reductions, 1, "timeStepReductions")
                        try budget.rejectStep()
                        rejectedSteps = try TransientExecutionBudget.add(rejectedSteps, 1, "rejectedSteps")
                        await observer?.emit(.timeStepRejected(TimeStepRejectInfo(id: analysisID,
                            time: currentTime, rejectedStep: oldDt, newStep: dt,
                            reason: "LTE exceeded tolerance (\(lte) > \(config.lteTolerance))")))
                        continue
                    }
                    let candidateState = SolutionState(variables: newtonSolutionBuf,
                        previousVariables: currentBuf, twoPreviousVariables: previousBuf, variableMap: variableMap,
                        variableLowComponents: compensated ? newtonSolutionLow : nil,
                        previousVariableLowComponents: compensated ? currentLow : nil,
                        twoPreviousVariableLowComponents: compensated ? previousLow : nil)
                    var candidateMaximum = Double.infinity
                    for device in devices {
                        if let constrained = device as? any TransientTrialTimeStepConstraintDevice,
                           let maximum = try constrained.maximumTransientTimeStep(state: candidateState, integration: currentIntegration) {
                            guard maximum.isFinite, maximum > 0 else { throw TransientExecutionError.invalidTimeStep(maximum) }
                            candidateMaximum = min(candidateMaximum, maximum)
                        }
                    }
                    if candidateMaximum < dt {
                        let oldDt = dt
                        guard dt > config.minTimeStep, candidateMaximum >= config.minTimeStep else {
                            throw AnalysisError.timestepTooSmall(candidateMaximum)
                        }
                        dt = candidateMaximum
                        reductions = try TransientExecutionBudget.add(reductions, 1, "timeStepReductions")
                        try budget.rejectStep()
                        rejectedSteps = try TransientExecutionBudget.add(rejectedSteps, 1, "rejectedSteps")
                        await observer?.emit(.timeStepRejected(TimeStepRejectInfo(id: analysisID,
                            time: currentTime, rejectedStep: oldDt, newStep: dt, reason: "Device candidate timestep bound")))
                        continue
                    }
                    if let physicalResidualEncloser {
                        guard let finalEncloser = transientResidualEncloser(currentBuf: currentBuf, previousBuf: previousBuf,
                            currentLow: currentLow, previousLow: previousLow, variableMap: variableMap, integration: currentIntegration),
                              let equationPolicy else { throw NumericalStateError.incompatiblePrecisionConfiguration }
                        var finalConfig = convergenceConfig
                        finalConfig.gmin = 0
                        var gate = NewtonRaphsonSolver(config: finalConfig, equationPolicy: equationPolicy,
                            physicalResidualEncloser: finalEncloser)
                        gate.executionBudget = budget
                        // Reference trials are dead after LTE; reuse their storage for the final certificate.
                        try gate.evaluateResidualEnclosure(finalEncloser, state: candidateState,
                            residual: &rhs, low: &quarterSolutionBuf, radii: &quarterSolutionLow,
                            nonZeroCount: plan.matrixStructure.nonZeroCount, cancellation: cancellation)
                        for index in 0..<dim {
                            let residual = try CompensatedEnclosure(center: CompensatedValue(high: rhs[index], low: quarterSolutionBuf[index]),
                                radius: quarterSolutionLow[index])
                            let tolerance = equationPolicy.rows[index].equationAbsoluteTolerance
                            guard residual.absoluteUpperBound <= tolerance else {
                                throw NonlinearPhysicalResidualError.uncertifiedResidual(row: index,
                                    upperBound: residual.absoluteUpperBound, tolerance: tolerance)
                            }
                        }
                        try physicalResidualEncloser.validate(state: candidateState, integration: currentIntegration)
                    }
                    try physicalResidualValidator?.validate(state: candidateState, integration: currentIntegration)
                    if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
                    let nextDt = max(config.minTimeStep,
                        min(lteEstimator.optimalTimeStep(currentStep: dt, lte: lte,
                            tolerance: config.lteTolerance, method: method), config.maxTimeStep))
                    try budget.admitSavedScalars(TransientExecutionBudget.add(auditScalars,
                        compensated ? dim : 0, "paired point audit scalars"))
                    try budget.admitSavedPoint(accepted: true)
                    try reserveResultPoint(timePoints.count + 1, capacity: &reservedPointCapacity,
                        maximumPoints: executionLimits.maximumSavedScalars / retainedPointScalars,
                        timePoints: &timePoints, trace: &solutionTrace, lowTrace: &solutionLowTrace, records: &integrationRecords,
                        retainedPointScalars: retainedPointScalars, operatingPointScalars: operatingPointScalars)
                    stepAccepted = true
                    swap(&twoPreviousBuf, &previousBuf)
                    swap(&previousBuf, &currentBuf)
                    swap(&currentBuf, &newtonSolutionBuf)
                    if compensated {
                        swap(&twoPreviousLow, &previousLow)
                        swap(&previousLow, &currentLow)
                        swap(&currentLow, &newtonSolutionLow)
                    }
                    let commitState = SolutionState(variables: currentBuf,
                        previousVariables: previousBuf, twoPreviousVariables: twoPreviousBuf, variableMap: variableMap,
                        variableLowComponents: compensated ? currentLow : nil,
                        previousVariableLowComponents: compensated ? previousLow : nil,
                        twoPreviousVariableLowComponents: compensated ? twoPreviousLow : nil)
                    for device in devices {
                        if let committing = device as? any TransientStateCommittingDevice {
                            try committing.commitTransientStep(state: commitState, integration: currentIntegration)
                        }
                    }
                    integrationRecords.append(TransientAcceptedStep(time: currentIntegration.currentTime,
                        timeStep: currentIntegration.timeStep, method: method, previousTimeStep: previousDt,
                        timeStepLowComponent: currentIntegration.timeStepLowComponent,
                        previousTimeStepLowComponent: previousDtLow))
                    acceptedOpticalState = currentOpticalState
                    twoPreviousDt = previousDt
                    twoPreviousDtLow = previousDtLow
                    previousDt = currentIntegration.timeStep
                    previousDtLow = compensated ? currentIntegration.timeStepLowComponent : nil
                    smoothHistoryCount = min(3, smoothHistoryCount + 1)
                    currentTime += dt
                    acceptedSteps += 1
                    timePoints.append(currentTime)
                    try currentBuf.withUnsafeBufferPointer { try solutionTrace.append($0) }
                    if compensated { try currentLow.withUnsafeBufferPointer { try solutionLowTrace?.append($0) } }
                    onStepAccepted?(currentTime, currentBuf)
                    await observer?.emit(.timeStepCompleted(TimeStepInfo(id: analysisID,
                        time: currentTime, timeStep: dt, iterations: newtonIterations, lte: lte)))
                    await observer?.emit(.progressUpdate(try ProgressInfo(id: analysisID,
                        fraction: min(currentTime / config.stopTime, 1), message: "Transient: t = \(currentTime) s")))
                    if breakpointMgr.isAtBreakpoint(currentTime) {
                        smoothHistoryCount = 1
                        previousDt = nil
                        twoPreviousDt = nil
                        previousDtLow = nil
                        twoPreviousDtLow = nil
                    }
                    dt = nextDt
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
                executionStatistics: budget.statistics,
                operatingPoint: operatingPoint, acceptedSteps: integrationRecords, solutionLowTrace: solutionLowTrace
            )

            for device in acquiredSessions.reversed() { device.endTransientSession() }
            acquiredSessions.removeAll(keepingCapacity: true)
            try completionFinalizer?.finalizeCompletion()

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .tran,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            if let resultStorage { return result.retainingStorage(resultStorage) }
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

    private func reserveResultPoint(_ count: Int, capacity: inout Int, maximumPoints: Int,
                                    timePoints: inout [Double], trace: inout SolutionTrace, lowTrace: inout SolutionTrace?,
                                    records: inout [TransientAcceptedStep], retainedPointScalars: Int, operatingPointScalars: Int) throws {
        guard let resultStorage, count > capacity else { return }
        let next = capacity + min(capacity, maximumPoints - capacity)
        guard next >= count else {
            throw TransientExecutionError.arithmeticOverflow("transient result capacity")
        }
        try resultStorage.reserveResultScalars(TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(next, retainedPointScalars, "transient result capacity"),
            operatingPointScalars, "transient OP and result capacity"))
        records.reserveCapacity(next)
        timePoints.reserveCapacity(next)
        try trace.reservePointCapacity(next)
        try lowTrace?.reservePointCapacity(next)
        capacity = next
    }

    /// Solves one trial from immutable accepted electrical and optical histories.
    private func solveTransientTrial(
        currentBuf: [Double], previousBuf: [Double], solution: inout [Double],
        currentLow: [Double], previousLow: [Double], solutionLow: inout [Double],
        acceptedOpticalState: OpticalState, opticalState: inout OpticalState,
        evaluator: OpticalNetworkEvaluator, opticalNetwork: OpticalNetworkGraph?,
        matrix: inout SparseMatrix, rhs: inout [Double], devices: [any BoundDevice],
        variableMap: [MNAVariable: Int], solver: inout any LinearSolver,
        integration: IntegrationState, allowGmin: Bool, observer: EventDispatcher?,
        analysisID: AnalysisID, cancellation: CancellationToken, executionBudget: TransientExecutionBudget
    ) async throws -> Int {
        let startingIterations = executionBudget.statistics.newtonIterations
        opticalState = acceptedOpticalState
        let residualEvaluator = transientResidualEvaluator(currentBuf: currentBuf, previousBuf: previousBuf,
            variableMap: variableMap, integration: integration)
        let encloser = transientResidualEncloser(currentBuf: currentBuf, previousBuf: previousBuf,
            currentLow: currentLow, previousLow: previousLow, variableMap: variableMap, integration: integration)
        var originalConfig = convergenceConfig
        originalConfig.gmin = 0
        var nr = NewtonRaphsonSolver(config: originalConfig, equationPolicy: equationPolicy,
            physicalResidualEvaluator: residualEvaluator, physicalResidualEncloser: encloser)
        nr.executionBudget = executionBudget
        nr.resultStorage = resultStorage
        do {
            _ = try await nr.solveInternal(
                initialGuess: currentBuf, initialLowComponents: physicalResidualEncloser == nil ? nil : currentLow,
                solution: &solution, solutionLowComponents: &solutionLow,
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
                        variableMap: variableMap,
                        variableLowComponents: state.variableLowComponents,
                        previousVariableLowComponents: physicalResidualEncloser == nil ? nil : currentLow,
                        twoPreviousVariableLowComponents: physicalResidualEncloser == nil ? nil : previousLow
                    )
                    // Evaluate optical network at each NR iteration
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
            return executionBudget.statistics.newtonIterations - startingIterations
        } catch let error as AnalysisError {
            guard case .convergenceFailure = error, allowGmin else { throw error }
            opticalState = acceptedOpticalState
            _ = try await tryGminStepping(currentBuf: currentBuf, previousBuf: previousBuf,
                solution: &solution, currentLow: currentLow, previousLow: previousLow, solutionLow: &solutionLow,
                opticalState: &opticalState, evaluator: evaluator,
                opticalNetwork: opticalNetwork, matrix: &matrix, rhs: &rhs, devices: devices,
                variableMap: variableMap, solver: &solver, integration: integration,
                observer: observer, analysisID: analysisID, cancellation: cancellation,
                executionBudget: executionBudget)
            return executionBudget.statistics.newtonIterations - startingIterations
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
        currentLow: [Double], previousLow: [Double], solutionLow: inout [Double],
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
        var guessLow = currentLow
        var totalIterations = 0

        var stages = config.gminStepping.lazyValues().makeIterator()
        var lastGmin: Double?
        while true {
            let gmin: Double
            if let stage = stages.next() { gmin = stage }
            else if lastGmin != 0 { gmin = 0 }
            else { break }
            lastGmin = gmin
            var stepConfig = convergenceConfig
            stepConfig.gmin = gmin

            let residualEvaluator = transientResidualEvaluator(currentBuf: currentBuf, previousBuf: previousBuf,
                variableMap: variableMap, integration: integration)
            let encloser = transientResidualEncloser(currentBuf: currentBuf, previousBuf: previousBuf,
                currentLow: currentLow, previousLow: previousLow, variableMap: variableMap, integration: integration)
            var nr = NewtonRaphsonSolver(config: stepConfig, equationPolicy: equationPolicy,
                physicalResidualEvaluator: residualEvaluator, physicalResidualEncloser: encloser)
            nr.executionBudget = executionBudget
            nr.resultStorage = resultStorage
            do {
                let iterations = try await nr.solveInternal(
                    initialGuess: guess, initialLowComponents: physicalResidualEncloser == nil ? nil : guessLow,
                    solution: &solution, solutionLowComponents: &solutionLow,
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
                            variableMap: variableMap,
                            variableLowComponents: state.variableLowComponents,
                            previousVariableLowComponents: physicalResidualEncloser == nil ? nil : currentLow,
                            twoPreviousVariableLowComponents: physicalResidualEncloser == nil ? nil : previousLow
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
                if physicalResidualEncloser != nil { swap(&guessLow, &solutionLow) }
                totalIterations += iterations
            } catch {
                throw error
            }
        }

        swap(&guess, &solution)
        if physicalResidualEncloser != nil { swap(&guessLow, &solutionLow) }
        return totalIterations
    }

    private func integrationState(method: IntegrationMethod, acceptedTime: Double, candidateTime: Double,
        proposedStep: Double, previousTimeStep: Double?, previousLow: Double?
    ) throws -> IntegrationState {
        if physicalResidualEncloser != nil {
            let interval = try CompensatedValue(high: candidateTime).subtracting(CompensatedValue(high: acceptedTime))
            guard interval.high > 0 else { throw TransientExecutionError.invalidTimeStep(interval.high) }
            return IntegrationState(method: method, timeStep: interval.high, currentTime: candidateTime,
                previousTimeStep: previousTimeStep, timeStepLowComponent: interval.low,
                previousTimeStepLowComponent: previousLow)
        }
        return IntegrationState(method: method, timeStep: proposedStep, currentTime: candidateTime,
            previousTimeStep: previousTimeStep)
    }

    private func transientResidualEncloser(currentBuf: [Double], previousBuf: [Double],
        currentLow: [Double], previousLow: [Double], variableMap: [MNAVariable: Int], integration: IntegrationState
    ) -> (any NonlinearPhysicalResidualEnclosing)? {
        guard let evaluator = physicalResidualEncloser else { return nil }
        return TransientStepPhysicalResidualEncloser(evaluator: evaluator,
            previousVariables: currentBuf, twoPreviousVariables: previousBuf,
            previousLowComponents: currentLow, twoPreviousLowComponents: previousLow,
            variableMap: variableMap, integration: integration)
    }

    private func transientResidualEvaluator(
        currentBuf: [Double], previousBuf: [Double], variableMap: [MNAVariable: Int], integration: IntegrationState
    ) -> (any NonlinearPhysicalResidualEvaluating)? {
        guard let evaluator = physicalResidualValidator as? any TransientPhysicalResidualEvaluating else { return nil }
        return TransientStepPhysicalResidualEvaluator(evaluator: evaluator, previousVariables: currentBuf,
            twoPreviousVariables: previousBuf, variableMap: variableMap, integration: integration)
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
