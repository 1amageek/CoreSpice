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

    public typealias Result = ACResult

    /// The frequency sweep specification.
    public let sweep: FrequencySweep

    /// Convergence configuration for the DC operating point solve.
    public let dcConfig: ConvergenceConfig

    public init(
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.sweep = sweep
        self.dcConfig = dcConfig
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> ACResult {
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap
        let frequencies = sweep.frequencies()

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .ac,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        // Phase 1: DC operating point (includes optical steady state)
        let dcAnalysis = DCAnalysis(config: dcConfig)
        let dcResult = try await dcAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: observer,
            cancellation: cancellation
        )
        let dcState = SolutionState(
            variables: dcResult.variables,
            variableMap: variableMap
        )
        let dcOpticalState = dcResult.opticalState ?? OpticalState()

        // Phase 2: AC frequency sweep
        var complexSolver = ComplexSparseLUSolver()
        var solutions: [[ComplexPair]] = []
        solutions.reserveCapacity(frequencies.count)

        var matrix = ComplexSparseMatrix(structure: plan.matrixStructure)
        var rhs = [ComplexPair](repeating: ComplexPair(), count: dim)
        var solutionBuf = [ComplexPair](repeating: ComplexPair(), count: dim)

        for (idx, freq) in frequencies.enumerated() {
            if cancellation.isCancelled {
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
                }
            )

            for device in devices {
                if let optoDevice = device as? OptoelectronicDevice {
                    optoDevice.stampAC(into: &stamper, state: dcState, opticalState: dcOpticalState, omega: omega)
                } else {
                    device.stampAC(into: &stamper, state: dcState, omega: omega)
                }
            }

            // Add Gmin to diagonal for numerical grounding
            for i in 0..<dim {
                matrix.addValue(row: i, col: i, value: ComplexPair(real: dcConfig.gmin, imag: 0))
            }

            // Solve the complex linear system
            do {
                try complexSolver.factorize(matrix: matrix)
            } catch {
                let message = "AC factorization failed at frequency \(freq) Hz: \(error)"
                await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                    id: analysisID,
                    type: .ac,
                    status: .failed,
                    timestamp: Timestamp(),
                    wallTime: Timestamp().elapsed(since: startTimestamp),
                    failure: AnalysisFailureInfo(error: error)
                )))
                if case CompileError.singularMatrix = error {
                    throw AnalysisError.singularMatrix
                }
                throw AnalysisError.internalError(message)
            }

            do {
                try complexSolver.solve(rhs: rhs, into: &solutionBuf)
            } catch {
                let message = "Complex solve failed at frequency \(freq) Hz: \(error)"
                await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                    id: analysisID,
                    type: .ac,
                    status: .failed,
                    timestamp: Timestamp(),
                    wallTime: Timestamp().elapsed(since: startTimestamp),
                    failure: AnalysisFailureInfo(reason: "complexSolveFailed", message: message)
                )))
                throw AnalysisError.internalError(message)
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
                await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                    id: analysisID,
                    type: .ac,
                    status: .failed,
                    timestamp: Timestamp(),
                    wallTime: Timestamp().elapsed(since: startTimestamp),
                    failure: AnalysisFailureInfo(reason: code.rawValue, message: message)
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

        await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
            id: analysisID,
            type: .ac,
            status: .completed,
            timestamp: Timestamp(),
            wallTime: Timestamp().elapsed(since: startTimestamp)
        )))

        return ACResult(
            frequencies: frequencies,
            solutions: solutions,
            variableMap: variableMap
        )
    }
}
