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

    public typealias Result = TransientResult

    /// Transient-specific configuration (stop time, timestep limits, LTE tolerance).
    public let config: TransientConfig

    /// Convergence configuration for the Newton-Raphson solver at each timestep.
    public let convergenceConfig: ConvergenceConfig

    /// Optional callback invoked after each accepted timestep.
    /// Called with (time, solutionVector) on the simulation thread.
    /// Designed for lightweight data capture (e.g., appending to a shared buffer).
    public let onStepAccepted: (@Sendable (_ time: Double, _ solution: [Double]) -> Void)?

    public init(
        config: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig(),
        onStepAccepted: (@Sendable (_ time: Double, _ solution: [Double]) -> Void)? = nil
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
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap

        // Extract branch current indices for LTE normalization
        let branchCurrentIndices: Set<Int> = Set(
            variableMap.compactMap { key, value in
                if case .branchCurrent = key { return value }
                return nil
            }
        )

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .tran,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            // Phase 1: Initial solution for t = 0
            let initialSolution: [Double]
            if config.useInitialConditions {
                // UIC mode: skip DC, build initial solution from device ICs
                initialSolution = Self.buildUICInitialSolution(
                    devices: devices,
                    variableMap: variableMap,
                    dimension: dim
                )
            } else {
                // Standard mode: DC operating point
                let dcAnalysis = DCAnalysis(config: convergenceConfig)
                let dcResult = try await dcAnalysis.run(
                    plan: plan,
                    devices: devices,
                    solver: solver,
                    observer: observer,
                    cancellation: cancellation
                )
                initialSolution = dcResult.variables
            }

            // Initialize state
            var currentTime: Double = 0.0

            // 3-buffer rotation: avoids allocation/deallocation per timestep.
            // currentBuf/previousBuf/twoPreviousBuf are swapped (O(1)) instead
            // of copied (O(n)) when advancing timesteps.
            var currentBuf = initialSolution
            var previousBuf = [Double](repeating: 0, count: dim)
            var twoPreviousBuf = [Double](repeating: 0, count: dim)
            var hasTwoPrevious = false
            // Initialize previousBuf to initialSolution
            for i in 0..<dim { previousBuf[i] = initialSolution[i] }

            // Optical state buffers (mirroring electrical buffer rotation)
            let evaluator = OpticalNetworkEvaluator()
            let opticalNodeCount = plan.opticalNetwork?.opticalNodeCount ?? 0
            var currentOpticalState = OpticalState(nodeCount: opticalNodeCount)
            var previousOpticalState = OpticalState(nodeCount: opticalNodeCount)

            // Saved results (pre-allocate estimated capacity)
            let estimatedSteps = max(
                Int(config.stopTime / (config.initialTimeStep ?? config.maxTimeStep / 10.0)),
                64
            )
            var timePoints: [Double] = [0.0]
            timePoints.reserveCapacity(estimatedSteps)
            var solutions: [[Double]] = [currentBuf]
            solutions.reserveCapacity(estimatedSteps)

            // Timestep control
            let initialDt = config.initialTimeStep ?? (config.maxTimeStep / 10.0)
            var dt = initialDt
            var previousDt: Double? = nil
            var method = config.initialMethod
            var acceptedSteps = 0
            var rejectedSteps = 0

            // Breakpoint management: collect from device waveforms
            var breakpointMgr = BreakpointManager()
            let breakpointInterval = 0.0...config.stopTime
            for device in devices {
                let deviceBreakpoints = device.breakpoints(in: breakpointInterval)
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
                if cancellation.isCancelled {
                    throw AnalysisError.cancelled
                }

                // Do not overshoot stopTime
                if currentTime + dt > config.stopTime {
                    dt = config.stopTime - currentTime
                }

                // Constrain by maximum timestep
                dt = min(dt, config.maxTimeStep)

                // Constrain by breakpoints
                dt = breakpointMgr.constrainTimeStep(
                    currentTime: currentTime,
                    proposedStep: dt
                )

                // Guard against zero or negative timestep
                if dt <= 0 {
                    break
                }

                // Attempt Newton-Raphson for this timestep
                var stepAccepted = false
                var reductions = 0

                while !stepAccepted && reductions <= config.maxTimeStepReductions {
                    if cancellation.isCancelled {
                        throw AnalysisError.cancelled
                    }

                    let currentIntegration = IntegrationState(
                        method: method,
                        timeStep: dt,
                        currentTime: currentTime + dt,
                        previousTimeStep: previousDt
                    )

                    // Newton-Raphson solve
                    let nr = NewtonRaphsonSolver(config: convergenceConfig)
                    var newtonResult: (solution: [Double], iterations: Int)

                    do {
                        newtonResult = try await nr.solve(
                            initialGuess: currentBuf,
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
                                        device.stampTransient(
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
                    } catch is AnalysisError {
                        // Newton failed: try GMIN stepping before reducing timestep
                        reductions += 1

                        if reductions == config.gminSteppingThreshold {
                            do {
                                let gminResult = try await tryGminStepping(
                                    currentBuf: currentBuf,
                                    previousBuf: previousBuf,
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
                                    cancellation: cancellation
                                )
                                // GMIN stepping succeeded — use this solution
                                newtonResult = gminResult
                            } catch {
                                // GMIN stepping failed — fall through to timestep reduction
                                let oldDt = dt
                                dt *= config.shrinkFactor
                                rejectedSteps += 1

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
                            rejectedSteps += 1

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
                            current: newtonResult.solution,
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

                        if lte > config.lteTolerance {
                            // LTE too large: reduce timestep and reject
                            let optDt = lteEstimator.optimalTimeStep(
                                currentStep: dt,
                                lte: lte,
                                tolerance: config.lteTolerance,
                                method: method
                            )
                            let oldDt = dt
                            dt = max(optDt, config.minTimeStep)
                            reductions += 1
                            rejectedSteps += 1

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

                        // Accept this step — O(1) buffer rotation
                        stepAccepted = true
                        swap(&twoPreviousBuf, &previousBuf)
                        swap(&previousBuf, &currentBuf)
                        newtonResult.solution.withUnsafeBufferPointer { src in
                            currentBuf.withUnsafeMutableBufferPointer { dst in
                                memcpy(dst.baseAddress!, src.baseAddress!, dim &* MemoryLayout<Double>.stride)
                            }
                        }
                        hasTwoPrevious = true

                        // Commit capacitor state for trapezoidal companion model.
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
                            if let cap = device as? BoundCapacitor {
                                cap.commitTransientStep(state: commitState, integration: commitIntegration)
                            }
                        }

                        previousOpticalState = currentOpticalState
                        previousDt = dt
                        currentTime += dt
                        acceptedSteps += 1

                        // Save the time point
                        timePoints.append(currentTime)
                        solutions.append(currentBuf)
                        onStepAccepted?(currentTime, currentBuf)

                        await observer?.emit(.timeStepCompleted(TimeStepInfo(
                            id: analysisID,
                            time: currentTime,
                            timeStep: dt,
                            iterations: newtonResult.iterations,
                            lte: lte
                        )))

                        // Emit progress
                        let fraction = min(currentTime / config.stopTime, 1.0)
                        await observer?.emit(.progressUpdate(ProgressInfo(
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
                        // First step: no LTE check, just accept — O(1) buffer rotation
                        stepAccepted = true
                        swap(&previousBuf, &currentBuf)
                        newtonResult.solution.withUnsafeBufferPointer { src in
                            currentBuf.withUnsafeMutableBufferPointer { dst in
                                memcpy(dst.baseAddress!, src.baseAddress!, dim &* MemoryLayout<Double>.stride)
                            }
                        }
                        // hasTwoPrevious stays false

                        // Commit capacitor state (first step is always BE).
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
                            if let cap = device as? BoundCapacitor {
                                cap.commitTransientStep(state: commitState, integration: commitIntegration)
                            }
                        }

                        previousOpticalState = currentOpticalState
                        previousDt = dt
                        currentTime += dt
                        acceptedSteps += 1

                        timePoints.append(currentTime)
                        solutions.append(currentBuf)
                        onStepAccepted?(currentTime, currentBuf)

                        await observer?.emit(.timeStepCompleted(TimeStepInfo(
                            id: analysisID,
                            time: currentTime,
                            timeStep: dt,
                            iterations: newtonResult.iterations,
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

            let result = TransientResult(
                timePoints: timePoints,
                solutions: solutions,
                variableMap: variableMap,
                timeSteps: acceptedSteps,
                rejectedSteps: rejectedSteps
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
        cancellation: CancellationToken
    ) async throws -> (solution: [Double], iterations: Int) {
        var x = currentBuf
        var totalIterations = 0

        for gmin in config.gminStepping.gminValues() {
            var stepConfig = convergenceConfig
            stepConfig.gmin = gmin

            let nr = NewtonRaphsonSolver(config: stepConfig)
            do {
                let result = try await nr.solve(
                    initialGuess: x,
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
                                device.stampTransient(
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
                x = result.solution
                totalIterations += result.iterations
            } catch {
                throw AnalysisError.internalError("GMIN stepping failed at gmin \(gmin): \(error)")
            }
        }

        return (solution: x, iterations: totalIterations)
    }

    /// Builds the initial solution vector from device initial conditions (UIC mode).
    ///
    /// Starts from a zero vector and applies each device's stored initial
    /// voltage or current to the corresponding matrix indices.
    private static func buildUICInitialSolution(
        devices: [any BoundDevice],
        variableMap: [MNAVariable: Int],
        dimension: Int
    ) -> [Double] {
        var solution = [Double](repeating: 0.0, count: dimension)

        for device in devices {
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

        return solution
    }
}
