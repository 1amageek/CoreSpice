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
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc, .transient], points: 1, cancellation: cancellation, observer: observer, analysis: .tran)
            return try await withTaskCancellationHandler {
                var analysis = self
                analysis.resultStorage = reservation
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                guard result.timePoints.last == config.stopTime, result.executionStatistics != nil,
                      result.solutionTrace.rowMajorValues.allSatisfy({ $0.isFinite }) else {
                    throw SPICENativeExecutionError.invalidOutput
                }
                return NativeCircuitRun(result: result, phases: [.init(record: record,
                    instances: record.plan.ir.instances, analysis: "tran", completedPointCount: result.timePoints.count, reservation: reservation)],
                    reservation: reservation, statistics: result.executionStatistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error) }
    }
}
