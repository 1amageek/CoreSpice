import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension ACAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<ACResult> {
        let (record, devices) = circuit.takeState()
        do {
            let points = try NativeCircuitExecution.frequencyPointCount(sweep)
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc, .ac], points: points, cancellation: cancellation, observer: observer, analysis: .ac, additionalRetainedBytes: NativeCircuitExecution.physicalValidationCapacity(record), allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = self
                if record.osdiLifetime != nil {
                    let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
                        config: dcConfig, cancellation: cancellation, prior: physicalResidualValidator)
                    analysis = ACAnalysis(sweep: sweep, dcConfig: dcConfig, nodeInitialGuess: nodeInitialGuess,
                        equationPolicy: try .init(rows: validator.rows), physicalResidualValidator: validator,
                        completionFinalizer: NativeOSDICompletionFinalizer(record: record, cancellation: cancellation, prior: completionFinalizer))
                }
                analysis.resultStorage = reservation
                analysis.executionBudget = budget
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                guard result.frequencies.count == points,
                      result.solutions.allSatisfy({ $0.allSatisfy { $0.real.isFinite && $0.imag.isFinite } }) else {
                    throw SPICENativeExecutionError.invalidOutput
                }
                return NativeCircuitRun(result: result, phases: NativeCircuitExecution.phases(record: record, operatingPoint: result.operatingPoint,
                    analysis: "ac", points: points, reservation: reservation), reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
}
