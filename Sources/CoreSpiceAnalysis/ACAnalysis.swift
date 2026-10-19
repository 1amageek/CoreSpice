import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Foundation

/// AC small-signal frequency-domain analysis.
///
/// The analysis proceeds in two phases:
/// 1. **DC operating point**: A full DC analysis is run first to find
///    the linearization point for the small-signal model.
/// 2. **Frequency sweep**: For each frequency in the sweep, the complex
///    MNA system `(G + j*omega*C) * V = I_s` is assembled and solved.
///
/// Each device stamps its linearised AC model (conductance + susceptance)
/// at the DC operating point through ``BoundDevice/stampAC(into:state:omega:)``.
public struct ACAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?

    public typealias Result = ACResult

    /// The frequency sweep specification.
    public let sweep: FrequencySweep

    /// Convergence configuration for the DC operating point solve.
    public let dcConfig: ConvergenceConfig
    public let nodeInitialGuess: [Node: Double]
    public let equationPolicy: DCEquationPolicy?
    public let physicalResidualValidator: (any DCPhysicalResidualValidating)?
    public let completionFinalizer: (any AnalysisCompletionFinalizing)?

    public init(
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        nodeInitialGuess: [Node: Double] = [:],
        equationPolicy: DCEquationPolicy? = nil,
        physicalResidualValidator: (any DCPhysicalResidualValidating)? = nil,
        completionFinalizer: (any AnalysisCompletionFinalizing)? = nil
    ) {
        self.sweep = sweep
        self.dcConfig = dcConfig
        self.nodeInitialGuess = nodeInitialGuess; self.equationPolicy = equationPolicy
        self.physicalResidualValidator = physicalResidualValidator; self.completionFinalizer = completionFinalizer
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> ACResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap
        let frequencies = try sweep.frequencies()

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .ac,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            // Phase 1: DC operating point (includes optical steady state)
            var dcAnalysis = DCAnalysis(config: dcConfig, nodeInitialGuess: nodeInitialGuess,
                equationPolicy: equationPolicy, physicalResidualValidator: physicalResidualValidator)
            dcAnalysis.executionBudget = executionBudget
            dcAnalysis.resultStorage = resultStorage
            try executionBudget?.admitSavedPoint(accepted: false)
            let dcResult = try await dcAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )
            let dcState = SolutionState(
                variables: dcResult.variables,
                variableMap: variableMap,
                variableLowComponents: dcResult.variableLowComponents
            )
            let dcOpticalState = dcResult.opticalState ?? OpticalState()

            // Phase 2: AC frequency sweep
            var complexSolver = ComplexSparseLUSolver()
            if executionBudget != nil || resultStorage != nil {
                try complexSolver.configureExecution(AnalysisLinearSolverControl.make(budget: executionBudget,
                    cancellation: cancellation, storage: resultStorage))
            }
            try executionBudget?.admitSavedScalars(TransientExecutionBudget.multiply(frequencies.count,
                TransientExecutionBudget.add(TransientExecutionBudget.multiply(dim, 2, "AC complex output scalars"),
                    1, "AC frequency scalar"), "AC saved sweep scalars"))
            try resultStorage?.reserveResultScalars(TransientExecutionBudget.add(dim,
                TransientExecutionBudget.multiply(frequencies.count, TransientExecutionBudget.add(
                    TransientExecutionBudget.multiply(dim, 2, "AC complex storage"), 1, "AC frequency storage"),
                    "AC result storage"), "AC OP storage"))
            var solutions: [[ComplexPair]] = []
            solutions.reserveCapacity(frequencies.count)

            var matrix = ComplexSparseMatrix(structure: plan.matrixStructure)
            var rhs = [ComplexPair](repeating: ComplexPair(), count: dim)
            var solutionBuf = [ComplexPair](repeating: ComplexPair(), count: dim)

            for (idx, freq) in frequencies.enumerated() {
                if cancellation.isCancelled || Task.isCancelled {
                    throw AnalysisError.cancelled
                }

                let omega = 2.0 * .pi * freq

                await observer?.emit(.sweepPointStarted(SweepPointInfo(
                    id: analysisID,
                    index: idx,
                    total: frequencies.count,
                    value: freq,
                    parameterName: "frequency"
                )))

                try executionBudget?.beginLinearSolve(complex: true)

                // Clear the complex system
                matrix.clear()
                for i in 0..<dim {
                    rhs[i] = ComplexPair()
                }

                // Stamp AC model: (G + j*omega*C) * V = I_s
                var stamper = ComplexMatrixStamper(
                    variableMap: variableMap,
                    stampMatrix: { row, col, re, im in
                        matrix.addValue(row: row, col: col, value: ComplexPair(real: re, imag: im))
                    },
                    stampRHS: { row, re, im in
                        rhs[row] = ComplexPair(
                            real: rhs[row].real + re,
                            imag: rhs[row].imag + im
                        )
                    },
                    stampValue: { index, real, imaginary in
                        matrix.addValueDirect(at: index, value: ComplexPair(real: real, imag: imaginary))
                    }
                )

                for device in devices {
                    if let optoDevice = device as? OptoelectronicDevice {
                        optoDevice.stampAC(into: &stamper, state: dcState, opticalState: dcOpticalState, omega: omega)
                    } else {
                        try device.stampAC(into: &stamper, state: dcState, omega: omega)
                    }
                }

                // Solve the complex linear system
                do {
                    try complexSolver.factorize(matrix: matrix)
                } catch {
                    if case CompileError.singularMatrix = error {
                        throw AnalysisError.singularMatrix
                    }
                    throw error
                }

                do {
                    try complexSolver.solve(rhs: rhs, into: &solutionBuf)
                } catch {
                    if case CompileError.singularMatrix = error { throw AnalysisError.singularMatrix }
                    throw error
                }

                var nonFiniteDiagnostic: DiagnosticCode?
                for val in solutionBuf {
                    if val.real.isNaN || val.real.isInfinite ||
                       val.imag.isNaN || val.imag.isInfinite {
                        nonFiniteDiagnostic = (val.real.isNaN || val.imag.isNaN)
                            ? .nanDetected
                            : .infDetected
                        break
                    }
                }

                if let code = nonFiniteDiagnostic {
                    let message = "Non-finite AC solution detected at frequency \(freq) Hz"
                    await observer?.emit(.warning(DiagnosticInfo(
                        id: analysisID,
                        code: code,
                        message: message,
                        timestamp: Timestamp()
                    )))
                    await observer?.emit(.sweepPointFinished(SweepPointResultInfo(
                        id: analysisID,
                        index: idx,
                        value: freq,
                        parameterName: "frequency",
                        converged: false,
                        iterations: 1
                    )))
                    throw AnalysisError.internalError(message)
                }

                solutions.append(solutionBuf)

                await observer?.emit(.sweepPointFinished(SweepPointResultInfo(
                    id: analysisID,
                    index: idx,
                    value: freq,
                    parameterName: "frequency",
                    converged: true,
                    iterations: 1
                )))
            }

            let result = try ACResult(frequencies: frequencies, solutions: solutions,
                variableMap: variableMap, operatingPoint: dcResult)
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try completionFinalizer?.finalizeCompletion()
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .ac,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            if let resultStorage { return result.retainingStorage(resultStorage) }
            return result
        } catch {
            let status: AnalysisStatus
            if let analysisError = error as? AnalysisError,
               case .cancelled = analysisError {
                status = .cancelled
            } else {
                status = .failed
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .ac,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }
}
