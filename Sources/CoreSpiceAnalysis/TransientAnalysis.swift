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

    public init(
        config: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.config = config
        self.convergenceConfig = convergenceConfig
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

        observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .tran,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            // Phase 1: DC operating point for t = 0
            let dcAnalysis = DCAnalysis(config: convergenceConfig)
            let dcResult = try await dcAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )

            // Initialize state
            var currentTime: Double = 0.0
            var currentSolution = dcResult.variables
            var previousSolution = dcResult.variables
            var twoPreviousSolution: [Double]? = nil

            // Saved results
            var timePoints: [Double] = [0.0]
            var solutions: [[Double]] = [currentSolution]

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
                        currentTime: currentTime + dt
                    )

                    // Newton-Raphson solve
                    let nr = NewtonRaphsonSolver(config: convergenceConfig)
                    let newtonResult: (solution: [Double], iterations: Int)

                    do {
                        newtonResult = try nr.solve(
                            initialGuess: currentSolution,
                            matrix: &matrix,
                            rhs: &rhs,
                            devices: devices,
                            variableMap: variableMap,
                            solver: &mutableSolver,
                            stampFunction: { stamper, state in
                                let transientState = SolutionState(
                                    variables: state.variables,
                                    previousVariables: currentSolution,
                                    variableMap: variableMap
                                )
                                for device in devices {
                                    device.stampTransient(
                                        into: &stamper,
                                        state: transientState,
                                        integration: currentIntegration
                                    )
                                }
                            },
                            observer: observer,
                            analysisID: analysisID,
                            cancellation: cancellation
                        )
                    } catch is AnalysisError {
                        // Newton failed: reduce timestep and retry
                        let oldDt = dt
                        dt *= config.shrinkFactor
                        reductions += 1
                        rejectedSteps += 1

                        observer?.emit(.timeStepRejected(TimeStepRejectInfo(
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

                    // LTE check (skip for the very first step)
                    if acceptedSteps > 0 {
                        let lte = lteEstimator.estimate(
                            current: newtonResult.solution,
                            previous: currentSolution,
                            twoPrevious: twoPreviousSolution,
                            timeStep: dt,
                            previousTimeStep: previousDt,
                            method: method
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

                            observer?.emit(.timeStepRejected(TimeStepRejectInfo(
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

                        // Accept this step
                        stepAccepted = true
                        twoPreviousSolution = previousSolution
                        previousSolution = currentSolution
                        currentSolution = newtonResult.solution
                        previousDt = dt
                        currentTime += dt
                        acceptedSteps += 1

                        // Save the time point
                        timePoints.append(currentTime)
                        solutions.append(currentSolution)

                        observer?.emit(.timeStepCompleted(TimeStepInfo(
                            id: analysisID,
                            time: currentTime,
                            timeStep: dt,
                            iterations: newtonResult.iterations,
                            lte: lte
                        )))

                        // Emit progress
                        let fraction = min(currentTime / config.stopTime, 1.0)
                        observer?.emit(.progressUpdate(ProgressInfo(
                            id: analysisID,
                            fraction: fraction,
                            message: "Transient: t = \(currentTime) s"
                        )))

                        // Update dt for next iteration
                        dt = nextDt
                    } else {
                        // First step: no LTE check, just accept
                        stepAccepted = true
                        twoPreviousSolution = nil
                        previousSolution = currentSolution
                        currentSolution = newtonResult.solution
                        previousDt = dt
                        currentTime += dt
                        acceptedSteps += 1

                        timePoints.append(currentTime)
                        solutions.append(currentSolution)

                        observer?.emit(.timeStepCompleted(TimeStepInfo(
                            id: analysisID,
                            time: currentTime,
                            timeStep: dt,
                            iterations: newtonResult.iterations,  // Fixed: use actual iteration count
                            lte: 0.0
                        )))

                        // Switch to Trapezoidal for subsequent steps
                        method = .trapezoidal
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

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
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

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .tran,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            throw error
        }
    }
}
