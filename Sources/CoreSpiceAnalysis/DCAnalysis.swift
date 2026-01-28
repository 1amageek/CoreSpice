import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

/// DC operating point analysis.
///
/// Finds the steady-state (DC) solution of the circuit by solving
/// the nonlinear MNA system `F(x) = 0` using Newton-Raphson iteration.
/// Convergence aids (Gmin stepping, source stepping) are available
/// but the primary path uses the Newton-Raphson solver directly.
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

        observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .dc,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            var matrix = SparseMatrix(structure: plan.matrixStructure)
            var rhs = [Double](repeating: 0, count: dim)
            var mutableSolver = solver

            let nr = NewtonRaphsonSolver(config: config)
            let x = try nr.solve(
                initialGuess: [Double](repeating: 0, count: dim),
                matrix: &matrix,
                rhs: &rhs,
                devices: devices,
                variableMap: variableMap,
                solver: &mutableSolver,
                stampFunction: { stamper, state in
                    for device in devices {
                        device.stampDC(into: &stamper, state: state)
                    }
                },
                observer: observer,
                analysisID: analysisID,
                cancellation: cancellation
            )

            let result = DCResult(
                variables: x,
                variableMap: variableMap,
                iterations: config.maxIterations
            )

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
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

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .dc,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            throw error
        }
    }
}
