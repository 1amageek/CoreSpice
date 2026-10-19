import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension TransferFunctionAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<TransferFunctionResult> {
        let (record, devices) = circuit.takeState()
        do {
            let points = 1
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc], points: points,
                cancellation: cancellation, observer: observer, analysis: .tf,
                additionalRetainedBytes: NativeCircuitExecution.physicalValidationCapacity(record), allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = self
                if record.osdiLifetime != nil {
                    let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
                        config: dcConfig, cancellation: cancellation, prior: physicalResidualValidator)
                    analysis = TransferFunctionAnalysis(outputNode: outputNode, inputSourceName: inputSourceName,
                        dcConfig: dcConfig, equationPolicy: try .init(rows: validator.rows), physicalResidualValidator: validator,
                        completionFinalizer: NativeOSDICompletionFinalizer(record: record,
                            cancellation: cancellation, prior: completionFinalizer))
                }
                analysis.executionBudget = budget
                analysis.resultStorage = reservation
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                return NativeCircuitRun(result: result, phases: [.init(record: record,
                    instances: record.plan.ir.instances, analysis: "tf", completedPointCount: points, reservation: reservation,
                    equationPolicy: analysis.equationPolicy)], reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
}
