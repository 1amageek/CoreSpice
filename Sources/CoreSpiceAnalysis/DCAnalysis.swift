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

    /// Convergence configuration for the Newton-Raphson solver.
    public let config: ConvergenceConfig

    /// Gmin stepping parameters for convergence assistance.
    public let gminStepping: GminStepping

    /// Source stepping parameters for convergence assistance.
    public let sourceStepping: SourceStepping

    public init(
        config: ConvergenceConfig = ConvergenceConfig(),
        gminStepping: GminStepping = GminStepping(),
        sourceStepping: SourceStepping = SourceStepping()
    ) {
        self.config = config
        self.gminStepping = gminStepping
        self.sourceStepping = sourceStepping
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> DCResult {
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
            // Share one solver instance across all phases so that
            // the SymbolicAnalysis cache and workspace buffers are reused.
            var mutableSolver = solver

            // Phase 1: Direct Newton-Raphson
            let result: DCResult
            do {
                result = try await solveNR(
                    config: config,
                    initialGuess: [Double](repeating: 0, count: dim),
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
                        solver: &mutableSolver,
                        variableMap: variableMap,
                        observer: observer,
                        analysisID: analysisID,
                        cancellation: cancellation
                    )
                    result = stepped
                } catch {
                    // Phase 3: Source stepping
                    result = try await solveWithSourceStepping(
                        plan: plan,
                        devices: devices,
                        solver: &mutableSolver,
                        variableMap: variableMap,
                        observer: observer,
                        analysisID: analysisID,
                        cancellation: cancellation
                    )
                }
            }

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
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            throw error
        }
    }

    // MARK: - Private

    private func solveNR(
        config: ConvergenceConfig,
        initialGuess: [Double],
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: inout any LinearSolver,
        variableMap: [MNAVariable: Int],
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> DCResult {
        var matrix = SparseMatrix(structure: plan.matrixStructure)
        var rhs = [Double](repeating: 0, count: plan.topology.dimension)

        // Optical network evaluation state (captured by stampFunction closure).
        // Updated at each NR iteration so the Jacobian includes optical-electrical coupling.
        let evaluator = OpticalNetworkEvaluator()
        var opticalState = OpticalState(
            nodeCount: plan.opticalNetwork?.opticalNodeCount ?? 0
        )

        let nr = NewtonRaphsonSolver(config: config)
        let result = try await nr.solve(
            initialGuess: initialGuess,
            matrix: &matrix,
            rhs: &rhs,
            devices: devices,
            variableMap: variableMap,
            solver: &solver,
            stampFunction: { stamper, state in
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
                    if let optoDevice = device as? OptoelectronicDevice {
                        optoDevice.stampDC(into: &stamper, state: state, opticalState: opticalState)
                    } else {
                        device.stampDC(into: &stamper, state: state)
                    }
                }
            },
            observer: observer,
            analysisID: analysisID,
            cancellation: cancellation
        )

        return DCResult(
            variables: result.solution,
            variableMap: variableMap,
            iterations: result.iterations,
            opticalState: plan.opticalNetwork != nil ? opticalState : nil
        )
    }

    private func solveWithGminStepping(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: inout any LinearSolver,
        variableMap: [MNAVariable: Int],
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> DCResult {
        let dim = plan.topology.dimension
        var x = [Double](repeating: 0, count: dim)
        var totalIterations = 0

        for gmin in gminStepping.gminValues() {
            var stepConfig = config
            stepConfig.gmin = gmin

            let result = try await solveNR(
                config: stepConfig,
                initialGuess: x,
                plan: plan,
                devices: devices,
                solver: &solver,
                variableMap: variableMap,
                observer: observer,
                analysisID: analysisID,
                cancellation: cancellation
            )
            x = result.variables
            totalIterations += result.iterations
        }

        return DCResult(
            variables: x,
            variableMap: variableMap,
            iterations: totalIterations
        )
    }

    private func solveWithSourceStepping(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: inout any LinearSolver,
        variableMap: [MNAVariable: Int],
        observer: EventDispatcher?,
        analysisID: AnalysisID,
        cancellation: CancellationToken
    ) async throws -> DCResult {
        let dim = plan.topology.dimension
        var x = [Double](repeating: 0, count: dim)
        var totalIterations = 0
        var matrix = SparseMatrix(structure: plan.matrixStructure)
        var rhs = [Double](repeating: 0, count: dim)

        // Optical network evaluation state (persists across source stepping factors)
        let evaluator = OpticalNetworkEvaluator()
        var opticalState = OpticalState(
            nodeCount: plan.opticalNetwork?.opticalNodeCount ?? 0
        )

        for factor in sourceStepping.sourceFactors() {
            let nr = NewtonRaphsonSolver(config: config)
            let result = try await nr.solve(
                initialGuess: x,
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
                            device.stampDC(into: &stamper, state: state)
                        }
                    }
                },
                observer: observer,
                analysisID: analysisID,
                cancellation: cancellation
            )
            x = result.solution
            totalIterations += result.iterations
        }

        return DCResult(
            variables: x,
            variableMap: variableMap,
            iterations: totalIterations,
            opticalState: plan.opticalNetwork != nil ? opticalState : nil
        )
    }
}
