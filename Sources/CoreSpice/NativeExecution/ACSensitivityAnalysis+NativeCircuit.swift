import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension ACSensitivityAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws -> NativeCircuitRun<ACSensitivityResult> {
        let (record, devices) = circuit.takeState()
        if !(deviceBinding is any SourceResolvingCircuitDeviceBinding), let instance = record.plan.ir.instances.first(where: { $0.mos != nil }) {
            throw AnalysisError.requiresFreshMOSResolution(instance: instance.name)
        }
        do {
            let points = try NativeCircuitExecution.frequencyPointCount(sweep)
            let sourceBinding = deviceBinding as? NativeSourceCircuitDeviceBinding
            let additional = try NativeCircuitExecution.capacitySum(NativeDiodeSensitivityBinding.capacities(record).retained,
                NativeCircuitExecution.capacitySum(NativeCircuitExecution.physicalValidationCapacity(record),
                    NativeCircuitExecution.dcOutputCapacity(record, points: 1)))
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc, .ac], points: points, cancellation: cancellation, observer: observer, analysis: .sens,
                additionalRetainedBytes: additional, allowOSDIOperatingPoint: sourceBinding != nil)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                let scratch = try NativeDiodeSensitivityBinding.reserve(record: record, storage: reservation)
                defer { withExtendedLifetime(scratch) {} }
                var analysis = ACSensitivityAnalysis(outputPositiveNode: outputPositiveNode, outputReferenceNode: outputReferenceNode,
                    sweep: sweep, dcConfig: dcConfig, nodeInitialGuess: nodeInitialGuess, perturbationFraction: perturbationFraction,
                    minimumPerturbation: minimumPerturbation,
                    deviceBinding: try NativeDiodeSensitivityBinding.binding(deviceBinding, record: record, capabilities: [.dc, .ac]))
                analysis.executionBudget = budget
                analysis.resultStorage = reservation
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                let ledger = try sourceBinding?.finishReexecutions(matching: result, reservation: reservation)
                let equationPolicy = record.osdiRuntimeInputs == nil ? nil
                    : try NativeOSDIPhysicalValidator.policy(record: record, config: dcConfig)
                var phases: [NativeCircuitExecutionFacts] = []
                if sourceBinding != nil {
                    guard result.operatingPoint != nil else { throw SPICENativeExecutionError.invalidOutput }
                    phases.append(.init(record: record, instances: record.plan.ir.instances, analysis: "op",
                        completedPointCount: 1, reservation: reservation, equationPolicy: equationPolicy))
                    phases.append(.init(record: record, instances: record.plan.ir.instances, analysis: "ac",
                        completedPointCount: result.frequencies.count, reservation: reservation, equationPolicy: equationPolicy))
                }
                phases.append(.init(record: record,
                    instances: record.plan.ir.instances, analysis: "sens-ac", completedPointCount: points, reservation: reservation,
                    diodePerturbationReceipts: result.sensitivities.compactMap(\.diodePreparation),
                    sourceReexecutionLedger: ledger))
                return NativeCircuitRun(result: result, phases: phases, reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch {
            if let source = deviceBinding as? NativeSourceCircuitDeviceBinding { throw source.failure(error, closing: record) }
            throw NativeCircuitExecution.failure(error, closing: record)
        }
    }
}
