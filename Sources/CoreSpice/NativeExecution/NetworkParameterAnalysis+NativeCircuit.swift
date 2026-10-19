import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension NetworkParameterAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<NetworkParameterResult> {
        let (record, devices) = circuit.takeState()
        do {
            guard limits.executionLimits == record.numericalLimits else {
                throw SPICENativeExecutionError.unsupportedCapability("Network and prepared numerical policies differ")
            }
            let metadata = try NativeCircuitExecution.capacitySum(
                NativeCircuitExecution.capacityProduct(UInt64(frequencies.count),
                    UInt64(MemoryLayout<NetworkParameterPoint>.stride + 6 * MemoryLayout<Array<Double>>.stride)),
                NativeCircuitExecution.capacityProduct(UInt64(ports.count), UInt64(MemoryLayout<NetworkPort>.stride)))
            let additional = try NativeCircuitExecution.capacitySum(metadata, NativeCircuitExecution.physicalValidationCapacity(record))
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc, .ac],
                points: frequencies.count, cancellation: cancellation, observer: observer, analysis: .networkParameters,
                additionalRetainedBytes: additional, allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = self
                var policy = equationPolicy
                if record.osdiLifetime != nil {
                    let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
                        config: dcConfig, cancellation: cancellation, prior: physicalResidualValidator)
                    policy = try .init(rows: validator.rows)
                    analysis = NetworkParameterAnalysis(frequencies: frequencies, ports: ports, limits: limits,
                        dcConfig: dcConfig, nodeInitialGuess: nodeInitialGuess, equationPolicy: policy,
                        physicalResidualValidator: validator, completionFinalizer: NativeOSDICompletionFinalizer(
                            record: record, cancellation: cancellation, prior: completionFinalizer))
                }
                analysis.executionBudget = budget; analysis.resultStorage = reservation
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                guard result.points.count == frequencies.count, result.ports == ports,
                      zip(result.points, frequencies).allSatisfy({ $0.0.frequency.bitPattern == $0.1.bitPattern }) else {
                    throw SPICENativeExecutionError.invalidOutput
                }
                return NativeCircuitRun(result: result, phases: NativeCircuitExecution.phases(record: record,
                    operatingPoint: result.operatingPoint, analysis: "network", points: frequencies.count,
                    reservation: reservation, equationPolicy: policy), reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
}
