import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR

extension DCAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<DCResult> {
        let (record, devices) = circuit.takeState()
        do {
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc], points: 1, cancellation: cancellation, observer: observer, analysis: .dc, additionalRetainedBytes: NativeCircuitExecution.capacitySum(NativeCircuitExecution.physicalValidationCapacity(record), NativeCircuitExecution.dcOutputCapacity(record, points: 1)), allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                var analysis = self
                if record.osdiLifetime != nil {
                    let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
                        config: config, cancellation: cancellation, prior: physicalResidualValidator)
                    analysis = DCAnalysis(config: config, gminStepping: gminStepping, sourceStepping: sourceStepping,
                        nodeInitialGuess: nodeInitialGuess, equationPolicy: try .init(rows: validator.rows),
                        physicalResidualValidator: validator, completionFinalizer: NativeOSDICompletionFinalizer(
                            record: record, cancellation: cancellation, prior: completionFinalizer), precisionMode: precisionMode)
                }
                let budget = try NativeCircuitExecution.budget(record)
                analysis.executionBudget = budget
                analysis.resultStorage = reservation
                try budget.admitSavedPoint(accepted: false)
                let result = try await analysis.run(plan: record.plan, devices: devices,
                    solver: solver, observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                return NativeCircuitRun(result: result, phases: [.init(record: record,
                    instances: record.plan.ir.instances, analysis: "op", completedPointCount: 1, reservation: reservation)],
                    reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }

    public func runSweep(circuit: consuming PreparedNativeCircuit, source: String, values: [Double],
                         solver: any LinearSolver, observer: EventDispatcher?, cancellation: CancellationToken,
                         onPointCompleted: (@Sendable (Int, Double, NativeCircuitExecutionFacts, DCResult) throws -> Void)? = nil)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<SweepResult<DCResult>> {
        let (record, initialDevices) = circuit.takeState()
        do {
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc], points: values.count,
                cancellation: cancellation, observer: observer, analysis: .dc,
                additionalRetainedBytes: NativeCircuitExecution.capacitySum(NativeCircuitExecution.dcOutputCapacity(record, points: values.count),
                    NativeCircuitExecution.physicalValidationCapacity(record)), allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                var devices = initialDevices
                var instances = record.plan.ir.instances
                var results: [DCResult] = []; results.reserveCapacity(values.count)
                var phases: [NativeCircuitExecutionFacts] = []; phases.reserveCapacity(values.count)
                var analysis = self
                let budget = try NativeCircuitExecution.budget(record)
                analysis.executionBudget = budget
                analysis.resultStorage = reservation
                let sweepPolicy: DCEquationPolicy?
                if record.osdiLifetime != nil {
                    sweepPolicy = try NativeOSDIPhysicalValidator.policy(record: record, config: config)
                } else { sweepPolicy = nil }
                for (index, value) in values.enumerated() {
                    try NativeCircuitExecution.check(cancellation)
                    try NativeCircuitExecution.checkResources(record)
                    try budget.admitSavedPoint(accepted: false)
                    try NativeCircuitExecution.replaceSource(record: record, name: source, value: value,
                        devices: &devices, instances: &instances)
                    var pointAnalysis = analysis
                    if let sweepPolicy {
                        let validator = try NativeCircuitExecution.physicalValidator(record: record, devices: devices,
                            config: config, cancellation: cancellation, prior: physicalResidualValidator, policy: sweepPolicy)
                        pointAnalysis = DCAnalysis(config: config, gminStepping: gminStepping, sourceStepping: sourceStepping,
                            nodeInitialGuess: nodeInitialGuess, equationPolicy: sweepPolicy,
                            physicalResidualValidator: validator, precisionMode: precisionMode)
                        pointAnalysis.executionBudget = budget
                        pointAnalysis.resultStorage = reservation
                    }
                    let numericalResult = try await pointAnalysis.run(plan: record.plan, devices: devices,
                        solver: solver, observer: observer, cancellation: cancellation)
                    let result = numericalResult.retainingStorage(reservation)
                    try NativeCircuitExecution.check(cancellation)
                    let facts = NativeCircuitExecutionFacts(record: record, instances: instances,
                        analysis: "dc", completedPointCount: 1, reservation: reservation, sourceName: source, sourceValue: value,
                        equationPolicy: pointAnalysis.equationPolicy)
                    try onPointCompleted?(index, value, facts, result)
                    results.append(result); phases.append(facts)
                }
                try NativeCircuitExecution.check(cancellation)
                if record.osdiLifetime != nil {
                    try NativeOSDICompletionFinalizer(record: record, cancellation: cancellation,
                        prior: completionFinalizer).finalizeCompletion()
                }
                return NativeCircuitRun(result: SweepResult(parameterName: source, values: values, results: results),
                    phases: phases, reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
}
