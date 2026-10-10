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
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc], points: points, cancellation: cancellation, observer: observer, analysis: .tf)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = self
                analysis.executionBudget = budget
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                return NativeCircuitRun(result: result, phases: [.init(record: record,
                    instances: record.plan.ir.instances, analysis: "tf", completedPointCount: points, reservation: reservation)], reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error) }
    }
}
