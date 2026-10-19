import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

/// Sensitivity (.sens) analysis.
///
/// Computes the DC sensitivity of a specified output node voltage to each
/// device parameter in the circuit using finite-difference perturbation.
///
/// For each parameter `p` with nominal value `p0`:
/// ```
/// sensitivity = (V_out(p0 + dp) - V_out(p0)) / dp
/// ```
/// where `dp = p0 * perturbationFraction`.
///
/// The analysis performs N+1 DC solves: one baseline plus one per parameter.
public struct SensitivityAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?

    public typealias Result = SensitivityResult

    /// The output node whose voltage sensitivity is computed.
    public let outputNode: Node

    /// Convergence configuration for each DC solve.
    public let dcConfig: ConvergenceConfig
    public let nodeInitialGuess: [Node: Double]

    /// Fractional perturbation applied to each parameter (default: 1e-6).
    public let perturbationFraction: Double

    /// Minimum absolute perturbation used for zero and near-zero parameters.
    public let minimumPerturbation: Double

    /// Device binding service used for every perturbed circuit.
    public let deviceBinding: any CircuitDeviceBinding

    public init(
        outputNode: Node,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        nodeInitialGuess: [Node: Double] = [:],
        perturbationFraction: Double = 1e-6,
        minimumPerturbation: Double = 1e-12,
        deviceBinding: any CircuitDeviceBinding = StandardCircuitDeviceBinding()
    ) {
        self.outputNode = outputNode
        self.dcConfig = dcConfig
        self.nodeInitialGuess = nodeInitialGuess
        self.perturbationFraction = perturbationFraction
        self.minimumPerturbation = minimumPerturbation
        self.deviceBinding = deviceBinding
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> SensitivityResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let variableMap = plan.topology.variableMap

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .sens,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            let perturbations: [CircuitParameterPerturbation]
            if let resolver = deviceBinding as? any SourceResolvingCircuitDeviceBinding {
                perturbations = try CircuitParameterPerturbation.makeSourceResolved(
                    parameters: resolver.sensitivityParameters(in: plan, cancellation: cancellation),
                    instances: plan.ir.instances, fraction: perturbationFraction,
                    minimumDelta: minimumPerturbation, cancellation: cancellation)
            } else {
                perturbations = try CircuitParameterPerturbation.makeAll(instances: plan.ir.instances,
                    fraction: perturbationFraction, minimumDelta: minimumPerturbation, cancellation: cancellation)
            }
            // Phase 1: Baseline DC operating point
            var dcAnalysis = DCAnalysis(config: dcConfig, nodeInitialGuess: nodeInitialGuess)
            dcAnalysis.executionBudget = executionBudget
            dcAnalysis.resultStorage = resultStorage
            if let resolver = deviceBinding as? any SourceResolvingCircuitDeviceBinding {
                dcAnalysis = try resolver.configureDCAnalysis(dcAnalysis, plan: plan, devices: devices,
                    cancellation: cancellation)
            }
            try executionBudget?.admitSavedPoint(accepted: false)
            let baselineResult = try await dcAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )

            guard variableMap[.nodeVoltage(outputNode)] != nil else {
                throw AnalysisError.invalidConfiguration(
                    "Output node \(outputNode.id) not found in variable map"
                )
            }
            try executionBudget?.admitSavedScalars(2)
            let baselineOutput = try baselineResult.checkedCompensatedVoltage(at: outputNode)
            let baselineValue = baselineOutput.high + baselineOutput.low
            let outputVariable = "V(\(outputNode.id))"

            // Phase 2: Perturb each parameter and recompute
            var sensitivities: [SensitivityResult.ParameterSensitivity] = []

            for perturbation in perturbations {
                if cancellation.isCancelled || Task.isCancelled {
                    throw AnalysisError.cancelled
                }

                try executionBudget?.chargeWork(TransientExecutionBudget.multiply(devices.count, 2, "sensitivity rebind work"))
                let perturbedCircuit = try await rebindDevices(
                    plan: plan,
                    perturbedInstanceIndex: perturbation.instanceIndex,
                    perturbedInstance: perturbation.perturbedInstance,
                    cancellation: cancellation
                )
                defer { withExtendedLifetime(perturbedCircuit) {} }

                let perturbedOutputNode = deviceBinding is any SourceResolvingCircuitDeviceBinding
                    ? try CircuitReexecution.outputNode(outputNode, from: plan, to: perturbedCircuit.plan)
                    : outputNode
                let perturbedGuesses = deviceBinding is any SourceResolvingCircuitDeviceBinding
                    ? try CircuitReexecution.nodeGuesses(nodeInitialGuess, from: plan, to: perturbedCircuit.plan)
                    : nodeInitialGuess
                var perturbedAnalysis = DCAnalysis(config: dcConfig, nodeInitialGuess: perturbedGuesses)
                perturbedAnalysis.resultStorage = resultStorage
                perturbedAnalysis.executionBudget = try executionBudget?.rebound(
                    dimension: perturbedCircuit.plan.topology.dimension,
                    nonZeroCount: perturbedCircuit.plan.matrixStructure.nonZeroCount,
                    deviceCount: perturbedCircuit.devices.count)
                try perturbedAnalysis.executionBudget?.admitSavedPoint(accepted: false)
                if let resolver = deviceBinding as? any SourceResolvingCircuitDeviceBinding {
                    perturbedAnalysis = try resolver.configureDCAnalysis(perturbedAnalysis, plan: perturbedCircuit.plan,
                        devices: perturbedCircuit.devices, cancellation: cancellation)
                }
                let perturbedResult = try await perturbedAnalysis.run(
                    plan: perturbedCircuit.plan,
                    devices: perturbedCircuit.devices,
                    solver: solver,
                    observer: nil,
                    cancellation: cancellation
                )

                let perturbedOutput = try perturbedResult.checkedCompensatedVoltage(at: perturbedOutputNode)
                let derivative = try perturbedOutput.subtracting(baselineOutput)
                    .divided(by: perturbation.effectiveIncrement)
                let sensitivity = derivative.high + derivative.low

                let normalizedSensitivity: Double?
                if abs(baselineValue) > 1e-30 {
                    normalizedSensitivity =
                        (sensitivity * perturbation.nominalValue) / baselineValue
                } else {
                    normalizedSensitivity = nil
                }

                try executionBudget?.chargeWork(96)
                try executionBudget?.admitSavedScalars(8)
                sensitivities.append(SensitivityResult.ParameterSensitivity(
                    deviceName: perturbation.deviceName,
                    parameterName: perturbation.parameterName,
                    nominalValue: perturbation.nominalValue,
                    sensitivity: sensitivity,
                    normalizedSensitivity: normalizedSensitivity,
                    perturbedValue: perturbation.perturbedValue,
                    effectiveIncrement: perturbation.effectiveIncrement,
                    perturbedOutput: perturbedOutput, outputNode: perturbedOutputNode,
                    diodePreparation: {
                        if case .prepared(let receipt) = perturbedCircuit.devices.first(where: { $0.instance.name == perturbation.deviceName })?.instance.diode { return receipt }
                        return nil
                    }()
                ))
            }

            let result = try SensitivityResult(
                outputVariable: outputVariable,
                baselineValue: baselineValue,
                sensitivities: sensitivities,
                dcOperatingPoint: baselineResult,
                baselineOutput: baselineOutput, outputNode: outputNode
            )
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .sens,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return result
        } catch {
            let status: AnalysisStatus
            if let analysisError = error as? AnalysisError,
               case .cancelled = analysisError {
                status = .cancelled
            } else {
                status = .failed
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .sens,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    // MARK: - Private

    /// Rebinds all device instances, substituting one perturbed instance.
    private func rebindDevices(
        plan: ExecutionPlan,
        perturbedInstanceIndex: Int,
        perturbedInstance: Instance,
        cancellation: CancellationToken
    ) async throws -> PreparedCircuit {
        var instances = plan.ir.instances
        instances[perturbedInstanceIndex] = perturbedInstance
        return try await deviceBinding.bind(plan: plan, instances: instances, cancellation: cancellation)
    }
}
