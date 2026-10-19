import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension TransientAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<TransientResult> {
        let (record, devices) = circuit.takeState()
        do {
            guard try config.requiredExecutionLimits() == record.numericalLimits else {
                throw SPICENativeExecutionError.unsupportedCapability("Transient numerical limits changed after preparation")
            }
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc, .transient], points: 1, cancellation: cancellation, observer: observer, analysis: .tran, additionalRetainedBytes: NativeCircuitExecution.physicalValidationCapacity(record), allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = try NativeCircuitExecution.configuredTransientAnalysis(self,
                    record: record, devices: devices, cancellation: cancellation, budget: budget)
                analysis.executionBudget = budget
                analysis.resultStorage = reservation
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                try NativeCircuitExecution.validateTransientResult(result, config: config,
                    precision: analysis.physicalResidualEncloser != nil)
                return NativeCircuitRun(result: result, phases: NativeCircuitExecution.phases(record: record, operatingPoint: result.operatingPoint,
                    analysis: "tran", points: result.timePoints.count, reservation: reservation, equationPolicy: analysis.equationPolicy),
                    reservation: reservation, statistics: result.executionStatistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
}
