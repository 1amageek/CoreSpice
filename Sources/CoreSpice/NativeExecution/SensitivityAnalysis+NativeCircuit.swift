import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension SensitivityAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws -> NativeCircuitRun<SensitivityResult> {
        let (record, devices) = circuit.takeState()
        if let instance = record.plan.ir.instances.first(where: { $0.mos != nil }) {
            throw AnalysisError.requiresFreshMOSResolution(instance: instance.name)
        }
        do {
            let points = 1
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc], points: points, cancellation: cancellation, observer: observer, analysis: .sens)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = self
                analysis.executionBudget = budget
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                return NativeCircuitRun(result: result, phases: [.init(record: record,
                    instances: record.plan.ir.instances, analysis: "sens", completedPointCount: points, reservation: reservation)], reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error) }
    }
}
