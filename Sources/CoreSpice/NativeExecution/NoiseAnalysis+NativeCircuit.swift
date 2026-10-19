import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension NoiseAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<NoiseResult> {
        let (record, devices) = circuit.takeState()
        do {
            let points = try NativeCircuitExecution.frequencyPointCount(sweep)
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc, .ac, .noise], points: points, cancellation: cancellation, observer: observer, analysis: .noise, additionalRetainedBytes: NativeCircuitExecution.physicalValidationCapacity(record), allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = self
                if record.osdiLifetime != nil {
                    let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
                        config: dcConfig, cancellation: cancellation, prior: physicalResidualValidator)
                    analysis = NoiseAnalysis(outputNode: outputNode, outputReferenceNode: outputReferenceNode,
                        inputSourceName: inputSourceName, sweep: sweep, dcConfig: dcConfig, nodeInitialGuess: nodeInitialGuess,
                        equationPolicy: try .init(rows: validator.rows), physicalResidualValidator: validator,
                        completionFinalizer: NativeOSDICompletionFinalizer(record: record, cancellation: cancellation, prior: completionFinalizer))
                }
                analysis.resultStorage = reservation
                analysis.executionBudget = budget
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                guard result.frequencies.count == points else { throw SPICENativeExecutionError.invalidOutput }
                return NativeCircuitRun(result: result, phases: NativeCircuitExecution.phases(record: record, operatingPoint: result.operatingPoint,
                    analysis: "noise", points: points, reservation: reservation), reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
}
