import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

extension FourierAnalysis {
    public func run(circuit: consuming PreparedNativeCircuit, solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> NativeCircuitRun<FourierResult> {
        let (record, devices) = circuit.takeState()
        do {
            guard try transientConfig.requiredExecutionLimits() == record.numericalLimits else {
                throw SPICENativeExecutionError.unsupportedCapability("Fourier numerical limits changed after preparation")
            }
            let (harmonics, countOverflow) = harmonicCount.addingReportingOverflow(1)
            let (componentCount, scalarOverflow) = harmonics.multipliedReportingOverflow(by: outputs.count)
            guard !countOverflow, !scalarOverflow, harmonicCount > 0, componentCount > 0,
                  componentCount <= record.numericalLimits.maximumSavedScalars else {
                throw SPICENativeExecutionError.unsupportedCapability("Fourier harmonic capacity exceeded")
            }
            let componentBytes = try NativeCircuitExecution.capacityProduct(UInt64(componentCount),
                UInt64(MemoryLayout<FourierResult.HarmonicComponent>.stride))
            // Both result dictionaries retain keys and array/value entries. Names are caller-owned
            // strings; admitting their UTF-8 extent also bounds newly materialized dictionary keys.
            var retainedBytes = componentBytes
            for output in outputs {
                retainedBytes = try NativeCircuitExecution.capacitySum(retainedBytes,
                    NativeCircuitExecution.capacitySum(256,
                        NativeCircuitExecution.capacityProduct(UInt64(output.name.utf8.count), 2)))
            }
            let reservation = try await NativeCircuitExecution.admit(record, capabilities: [.dc, .transient],
                points: 1, cancellation: cancellation, observer: observer, analysis: .fourier,
                additionalRetainedBytes: NativeCircuitExecution.capacitySum(retainedBytes,
                    NativeCircuitExecution.physicalValidationCapacity(record)), allowOSDIOperatingPoint: true)
            return try await withTaskCancellationHandler {
                let budget = try NativeCircuitExecution.budget(record)
                var analysis = self
                if record.osdiLifetime != nil {
                    let transient = try NativeCircuitExecution.configuredTransientAnalysis(
                        TransientAnalysis(config: transientConfig, convergenceConfig: convergenceConfig),
                        record: record, devices: devices, cancellation: cancellation, budget: budget, finalizeOnCompletion: false)
                    analysis = FourierAnalysis(fundamentalFrequency: fundamentalFrequency, harmonicCount: harmonicCount,
                        outputs: outputs, transientConfig: transientConfig, convergenceConfig: convergenceConfig,
                        completionFinalizer: NativeOSDICompletionFinalizer(record: record,
                            cancellation: cancellation, prior: completionFinalizer))
                    analysis.preparedTransientAnalysis = transient
                }
                analysis.executionBudget = budget
                analysis.resultStorage = reservation
                let result = try await analysis.run(plan: record.plan, devices: devices, solver: solver,
                    observer: observer, cancellation: cancellation)
                try NativeCircuitExecution.check(cancellation)
                try NativeCircuitExecution.validateTransientResult(result.transientResult, config: transientConfig,
                    precision: analysis.preparedTransientAnalysis?.physicalResidualEncloser != nil)
                guard result.transientResult.timePoints.last == transientConfig.stopTime,
                      result.transientResult.executionStatistics != nil,
                      result.harmonics.values.allSatisfy({ components in
                          components.count == harmonics && components.allSatisfy {
                              $0.frequency.isFinite && $0.magnitude.isFinite && $0.phase.isFinite && $0.normalizedMagnitude.isFinite
                          }
                      }), result.thd.values.allSatisfy({ $0.isFinite }) else {
                    throw SPICENativeExecutionError.invalidOutput
                }
                let phases: [NativeCircuitExecutionFacts]
                if record.osdiLifetime != nil {
                    phases = NativeCircuitExecution.phases(record: record,
                        operatingPoint: result.transientResult.operatingPoint, analysis: "fourier",
                        points: result.transientResult.timePoints.count, reservation: reservation,
                        equationPolicy: analysis.preparedTransientAnalysis?.equationPolicy)
                } else {
                    phases = [.init(record: record, instances: record.plan.ir.instances, analysis: "fourier",
                        completedPointCount: result.transientResult.timePoints.count, reservation: reservation)]
                }
                return NativeCircuitRun(result: result, phases: phases,
                    reservation: reservation, statistics: budget.statistics)
            } onCancel: { cancellation.cancel() }
        } catch { throw NativeCircuitExecution.failure(error, closing: record) }
    }
}
