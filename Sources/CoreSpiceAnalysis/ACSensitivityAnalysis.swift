import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR

/// Frequency-dependent finite-difference sensitivity analysis.
public struct ACSensitivityAnalysis: Analysis, Sendable {
    public typealias Result = ACSensitivityResult

    public let outputPositiveNode: Node
    public let outputReferenceNode: Node
    public let sweep: FrequencySweep
    public let dcConfig: ConvergenceConfig
    public let perturbationFraction: Double
    public let minimumPerturbation: Double
    public let deviceBinding: any CircuitDeviceBinding

    public init(
        outputPositiveNode: Node,
        outputReferenceNode: Node = .ground,
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        perturbationFraction: Double = 1e-6,
        minimumPerturbation: Double = 1e-12,
        deviceBinding: any CircuitDeviceBinding = StandardCircuitDeviceBinding()
    ) {
        self.outputPositiveNode = outputPositiveNode
        self.outputReferenceNode = outputReferenceNode
        self.sweep = sweep
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
    ) async throws -> ACSensitivityResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        try validateOutput(plan: plan)
        let perturbations = try CircuitParameterPerturbation.makeAll(
            instances: plan.ir.instances,
            fraction: perturbationFraction,
            minimumDelta: minimumPerturbation
        )
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .sens,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            let acAnalysis = ACAnalysis(sweep: sweep, dcConfig: dcConfig)
            let baseline = try await acAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            let baselineValues = baseline.solutions.map {
                outputVoltage($0, variableMap: baseline.variableMap)
            }
            var entries: [ACSensitivityResult.ParameterSensitivity] = []
            entries.reserveCapacity(perturbations.count)

            for (index, perturbation) in perturbations.enumerated() {
                if cancellation.isCancelled {
                    throw AnalysisError.cancelled
                }
                var instances = plan.ir.instances
                instances[perturbation.instanceIndex] = perturbation.perturbedInstance
                let prepared = try deviceBinding.bind(plan: plan, instances: instances)
                let perturbed = try await acAnalysis.run(
                    plan: plan,
                    devices: prepared.devices,
                    solver: solver,
                    observer: nil,
                    cancellation: cancellation
                )
                guard perturbed.frequencies == baseline.frequencies else {
                    throw AnalysisError.internalError(
                        "Perturbed AC sensitivity sweep does not match the baseline sweep"
                    )
                }

                let perturbedValues = perturbed.solutions.map {
                    outputVoltage($0, variableMap: perturbed.variableMap)
                }
                var derivatives: [ComplexPair] = []
                var normalized: [ComplexPair?] = []
                derivatives.reserveCapacity(baselineValues.count)
                normalized.reserveCapacity(baselineValues.count)
                for (base, changed) in zip(baselineValues, perturbedValues) {
                    let derivative = ComplexPair(
                        real: (changed.real - base.real) / perturbation.delta,
                        imag: (changed.imag - base.imag) / perturbation.delta
                    )
                    derivatives.append(derivative)
                    if base.magnitude > 1e-30 {
                        normalized.append(
                            derivative
                                * ComplexPair(real: perturbation.nominalValue)
                                / base
                        )
                    } else {
                        normalized.append(nil)
                    }
                }
                entries.append(ACSensitivityResult.ParameterSensitivity(
                    deviceName: perturbation.deviceName,
                    parameterName: perturbation.parameterName,
                    nominalValue: perturbation.nominalValue,
                    sensitivities: derivatives,
                    normalizedSensitivities: normalized
                ))
                await observer?.emit(.progressUpdate(try ProgressInfo(
                    id: analysisID,
                    fraction: Double(index + 1) / Double(max(perturbations.count, 1)),
                    message: "Computed AC sensitivity for \(perturbation.deviceName).\(perturbation.parameterName)"
                )))
            }

            let result = try ACSensitivityResult(
                outputVariable: outputName(plan: plan),
                frequencies: baseline.frequencies,
                baselineValues: baselineValues,
                sensitivities: entries
            )
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

    private func validateOutput(plan: ExecutionPlan) throws {
        guard outputPositiveNode != outputReferenceNode else {
            throw AnalysisError.invalidConfiguration(
                "AC sensitivity output nodes must be distinct"
            )
        }
        for node in [outputPositiveNode, outputReferenceNode]
        where node != plan.ir.groundNode {
            guard plan.topology.variableMap[.nodeVoltage(node)] != nil else {
                throw AnalysisError.invalidConfiguration(
                    "AC sensitivity output node \(node.id) is not present in the circuit"
                )
            }
        }
    }

    private func outputVoltage(
        _ solution: [ComplexPair],
        variableMap: [MNAVariable: Int]
    ) -> ComplexPair {
        func voltage(_ node: Node) -> ComplexPair {
            guard node != .ground,
                  let index = variableMap[.nodeVoltage(node)] else {
                return .zero
            }
            return solution[index]
        }
        return voltage(outputPositiveNode) - voltage(outputReferenceNode)
    }

    private func outputName(plan: ExecutionPlan) -> String {
        let positive = plan.ir.name(for: outputPositiveNode)
            ?? String(outputPositiveNode.id)
        if outputReferenceNode == plan.ir.groundNode {
            return "V(\(positive))"
        }
        let reference = plan.ir.name(for: outputReferenceNode)
            ?? String(outputReferenceNode.id)
        return "V(\(positive),\(reference))"
    }
}
