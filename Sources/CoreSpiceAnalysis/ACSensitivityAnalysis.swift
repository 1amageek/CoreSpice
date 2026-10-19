import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR

/// Frequency-dependent finite-difference sensitivity analysis.
public struct ACSensitivityAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?
    public typealias Result = ACSensitivityResult

    public let outputPositiveNode: Node
    public let outputReferenceNode: Node
    public let sweep: FrequencySweep
    public let dcConfig: ConvergenceConfig
    public let nodeInitialGuess: [Node: Double]
    public let perturbationFraction: Double
    public let minimumPerturbation: Double
    public let deviceBinding: any CircuitDeviceBinding

    public init(
        outputPositiveNode: Node,
        outputReferenceNode: Node = .ground,
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        nodeInitialGuess: [Node: Double] = [:],
        perturbationFraction: Double = 1e-6,
        minimumPerturbation: Double = 1e-12,
        deviceBinding: any CircuitDeviceBinding = StandardCircuitDeviceBinding()
    ) {
        self.outputPositiveNode = outputPositiveNode
        self.outputReferenceNode = outputReferenceNode
        self.sweep = sweep
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
    ) async throws -> ACSensitivityResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        try validateOutput(plan: plan)
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
            var acAnalysis = ACAnalysis(sweep: sweep, dcConfig: dcConfig, nodeInitialGuess: nodeInitialGuess)
            acAnalysis.executionBudget = executionBudget
            acAnalysis.resultStorage = resultStorage
            if let resolver = deviceBinding as? any SourceResolvingCircuitDeviceBinding {
                acAnalysis = try resolver.configureACAnalysis(acAnalysis, plan: plan, devices: devices,
                    cancellation: cancellation)
            }
            let baseline = try await acAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: cancellation
            )
            try executionBudget?.admitSavedScalars(TransientExecutionBudget.multiply(baseline.solutions.count, 2, "AC sensitivity baseline scalars"))
            let baselineValues = baseline.solutions.map {
                outputVoltage($0, variableMap: baseline.variableMap)
            }
            var entries: [ACSensitivityResult.ParameterSensitivity] = []
            entries.reserveCapacity(perturbations.count)

            for (index, perturbation) in perturbations.enumerated() {
                if cancellation.isCancelled || Task.isCancelled {
                    throw AnalysisError.cancelled
                }
                try executionBudget?.chargeWork(TransientExecutionBudget.multiply(devices.count, 2, "AC sensitivity rebind work"))
                var instances = plan.ir.instances
                instances[perturbation.instanceIndex] = perturbation.perturbedInstance
                let prepared = try await deviceBinding.bind(plan: plan, instances: instances, cancellation: cancellation)
                defer { withExtendedLifetime(prepared) {} }
                let changedPositive = deviceBinding is any SourceResolvingCircuitDeviceBinding
                    ? try CircuitReexecution.outputNode(outputPositiveNode, from: plan, to: prepared.plan)
                    : outputPositiveNode
                let changedReference = deviceBinding is any SourceResolvingCircuitDeviceBinding
                    ? try CircuitReexecution.outputNode(outputReferenceNode, from: plan, to: prepared.plan)
                    : outputReferenceNode
                let perturbedGuesses = deviceBinding is any SourceResolvingCircuitDeviceBinding
                    ? try CircuitReexecution.nodeGuesses(nodeInitialGuess, from: plan, to: prepared.plan)
                    : nodeInitialGuess
                var perturbedAnalysis = ACAnalysis(sweep: sweep, dcConfig: dcConfig, nodeInitialGuess: perturbedGuesses)
                perturbedAnalysis.resultStorage = resultStorage
                perturbedAnalysis.executionBudget = try executionBudget?.rebound(
                    dimension: prepared.plan.topology.dimension,
                    nonZeroCount: prepared.plan.matrixStructure.nonZeroCount,
                    deviceCount: prepared.devices.count)
                if let resolver = deviceBinding as? any SourceResolvingCircuitDeviceBinding {
                    perturbedAnalysis = try resolver.configureACAnalysis(perturbedAnalysis, plan: prepared.plan,
                        devices: prepared.devices, cancellation: cancellation)
                }
                let perturbed = try await perturbedAnalysis.run(
                    plan: prepared.plan,
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

                try executionBudget?.chargeWork(TransientExecutionBudget.multiply(baselineValues.count, 256, "AC sensitivity derivative work"))
                try executionBudget?.admitSavedScalars(TransientExecutionBudget.add(
                    TransientExecutionBudget.multiply(baselineValues.count, 6, "AC sensitivity derivative and child scalars"), 4, "AC sensitivity parameter and increment scalars"))
                let perturbedValues = perturbed.solutions.map {
                    outputVoltage($0, variableMap: perturbed.variableMap, positive: changedPositive, reference: changedReference)
                }
                var derivatives: [ComplexPair] = []
                var normalized: [ComplexPair?] = []
                derivatives.reserveCapacity(baselineValues.count)
                normalized.reserveCapacity(baselineValues.count)
                for (base, changed) in zip(baselineValues, perturbedValues) {
                    let real = try CompensatedValue(high: changed.real).subtracting(CompensatedValue(high: base.real))
                        .divided(by: perturbation.effectiveIncrement)
                    let imaginary = try CompensatedValue(high: changed.imag).subtracting(CompensatedValue(high: base.imag))
                        .divided(by: perturbation.effectiveIncrement)
                    let derivative = ComplexPair(real: real.high + real.low, imag: imaginary.high + imaginary.low)
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
                    normalizedSensitivities: normalized,
                    perturbedValue: perturbation.perturbedValue,
                    effectiveIncrement: perturbation.effectiveIncrement,
                    perturbedValues: perturbedValues, outputPositiveNode: changedPositive,
                    outputReferenceNode: changedReference,
                    diodePreparation: {
                        if case .prepared(let receipt) = prepared.devices.first(where: { $0.instance.name == perturbation.deviceName })?.instance.diode { return receipt }
                        return nil
                    }()
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
                sensitivities: entries,
                outputPositiveNode: outputPositiveNode, outputReferenceNode: outputReferenceNode,
                operatingPoint: baseline.operatingPoint
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
        variableMap: [MNAVariable: Int],
        positive: Node? = nil, reference: Node? = nil
    ) -> ComplexPair {
        func voltage(_ node: Node) -> ComplexPair {
            guard node != .ground,
                  let index = variableMap[.nodeVoltage(node)] else {
                return .zero
            }
            return solution[index]
        }
        return voltage(positive ?? outputPositiveNode) - voltage(reference ?? outputReferenceNode)
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
