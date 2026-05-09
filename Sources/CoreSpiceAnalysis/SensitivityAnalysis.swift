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

    public init(
        outputNode: Node,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        perturbationFraction: Double = 1e-6
    ) {
        self.outputNode = outputNode
        self.dcConfig = dcConfig
        self.perturbationFraction = perturbationFraction
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> SensitivityResult {
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
            let registry = DeviceRegistry.standard()
            var sensitivities: [SensitivityResult.ParameterSensitivity] = []

            for (instanceIndex, instance) in plan.ir.instances.enumerated() {
                if cancellation.isCancelled {
                    throw AnalysisError.cancelled
                }

                for (paramName, paramValue) in instance.parameters {
                    guard case .real(let nominalValue) = paramValue else { continue }
                    guard abs(nominalValue) > 1e-30 else { continue }

                    let dp = nominalValue * perturbationFraction
                    let perturbedValue = nominalValue + dp

                    // Create perturbed instance
                    var perturbedParams = instance.parameters
                    perturbedParams[paramName] = .real(perturbedValue)
                    let perturbedInstance = Instance(
                        name: instance.name,
                        typeName: instance.typeName,
                        nodes: instance.nodes,
                        parameters: perturbedParams
                    )

                    // Rebind all devices with the perturbed instance
                    let perturbedDevices = try rebindDevices(
                        plan: plan,
                        registry: registry,
                        perturbedInstanceIndex: instanceIndex,
                        perturbedInstance: perturbedInstance
                    )

                    // Solve perturbed DC
                    let perturbedResult = try await dcAnalysis.run(
                        plan: plan,
                        devices: perturbedDevices,
                        solver: solver,
                        observer: nil,
                        cancellation: cancellation
                    )

                    let perturbedOutput = perturbedResult.variables[outputIndex]
                    let sensitivity = (perturbedOutput - baselineValue) / dp

                    let normalizedSensitivity: Double
                    if abs(baselineValue) > 1e-30 {
                        normalizedSensitivity = (sensitivity * nominalValue) / baselineValue
                    } else {
                        normalizedSensitivity = 0.0
                    }

                    sensitivities.append(SensitivityResult.ParameterSensitivity(
                        deviceName: instance.name,
                        parameterName: paramName,
                        nominalValue: nominalValue,
                        sensitivity: sensitivity,
                        normalizedSensitivity: normalizedSensitivity
                    ))
                }
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .sens,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return SensitivityResult(
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
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            throw error
        }
    }

    // MARK: - Private

    /// Rebinds all device instances, substituting one perturbed instance.
    private func rebindDevices(
        plan: ExecutionPlan,
        registry: DeviceRegistry,
        perturbedInstanceIndex: Int,
        perturbedInstance: Instance
    ) throws -> [any BoundDevice] {
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []

        for (i, instance) in plan.ir.instances.enumerated() {
            let inst = (i == perturbedInstanceIndex) ? perturbedInstance : instance
            guard let desc = registry.descriptor(for: inst.typeName) else { continue }
            let bound = try desc.bind(instance: inst, context: &context)
            devices.append(bound)
        }

        return devices
    }
}
