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

    public typealias Result = SensitivityResult

    /// The output node whose voltage sensitivity is computed.
    public let outputNode: Node

    /// Convergence configuration for each DC solve.
    public let dcConfig: ConvergenceConfig

    /// Fractional perturbation applied to each parameter (default: 1e-6).
    public let perturbationFraction: Double

    /// Minimum absolute perturbation used for zero and near-zero parameters.
    public let minimumPerturbation: Double

    /// Device binding service used for every perturbed circuit.
    public let deviceBinding: any CircuitDeviceBinding

    public init(
        outputNode: Node,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        perturbationFraction: Double = 1e-6,
        minimumPerturbation: Double = 1e-12,
        deviceBinding: any CircuitDeviceBinding = StandardCircuitDeviceBinding()
    ) {
        self.outputNode = outputNode
        self.dcConfig = dcConfig
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
            let perturbations = try CircuitParameterPerturbation.makeAll(
                instances: plan.ir.instances,
                fraction: perturbationFraction,
                minimumDelta: minimumPerturbation
            )
            // Phase 1: Baseline DC operating point
            let dcAnalysis = DCAnalysis(config: dcConfig)
            let baselineResult = try await dcAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )

            guard let outputIndex = variableMap[.nodeVoltage(outputNode)] else {
                throw AnalysisError.invalidConfiguration(
                    "Output node \(outputNode.id) not found in variable map"
                )
            }
            let baselineValue = baselineResult.variables[outputIndex]
            let outputVariable = "V(\(outputNode.id))"

            // Phase 2: Perturb each parameter and recompute
            var sensitivities: [SensitivityResult.ParameterSensitivity] = []

            for perturbation in perturbations {
                if cancellation.isCancelled {
                    throw AnalysisError.cancelled
                }

                let perturbedCircuit = try rebindDevices(
                    plan: plan,
                    perturbedInstanceIndex: perturbation.instanceIndex,
                    perturbedInstance: perturbation.perturbedInstance
                )

                let perturbedResult = try await dcAnalysis.run(
                    plan: plan,
                    devices: perturbedCircuit.devices,
                    solver: solver,
                    observer: nil,
                    cancellation: cancellation
                )

                let perturbedOutput = perturbedResult.variables[outputIndex]
                let sensitivity = (perturbedOutput - baselineValue) / perturbation.delta

                let normalizedSensitivity: Double?
                if abs(baselineValue) > 1e-30 {
                    normalizedSensitivity =
                        (sensitivity * perturbation.nominalValue) / baselineValue
                } else {
                    normalizedSensitivity = nil
                }

                sensitivities.append(SensitivityResult.ParameterSensitivity(
                    deviceName: perturbation.deviceName,
                    parameterName: perturbation.parameterName,
                    nominalValue: perturbation.nominalValue,
                    sensitivity: sensitivity,
                    normalizedSensitivity: normalizedSensitivity
                ))
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .sens,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return try SensitivityResult(
                outputVariable: outputVariable,
                baselineValue: baselineValue,
                sensitivities: sensitivities,
                dcOperatingPoint: baselineResult
            )
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
        perturbedInstance: Instance
    ) throws -> PreparedCircuit {
        var instances = plan.ir.instances
        instances[perturbedInstanceIndex] = perturbedInstance
        return try deviceBinding.bind(plan: plan, instances: instances)
    }
}
