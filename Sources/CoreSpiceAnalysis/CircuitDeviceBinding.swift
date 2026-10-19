import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceDiodeContracts
import CoreSpiceEvent

/// Binds a complete circuit instance set without owning compilation or analysis.
public protocol CircuitDeviceBinding: Sendable {
    func bind(
        plan: ExecutionPlan,
        instances: [Instance]
    ) throws -> PreparedCircuit

    /// Prepares complete owners asynchronously when source/model acquisition requires suspension.
    func bind(plan: ExecutionPlan, instances: [Instance], cancellation: CancellationToken) async throws -> PreparedCircuit
}

extension CircuitDeviceBinding {
    public func bind(plan: ExecutionPlan, instances: [Instance], cancellation: CancellationToken) async throws -> PreparedCircuit {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        let prepared = try bind(plan: plan, instances: instances)
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        return prepared
    }
}

/// Production device-binding service backed by an injected registry.
public struct StandardCircuitDeviceBinding: CircuitDeviceBinding, Sendable {
    public let registry: DeviceRegistry
    public let operatingConditions: OperatingConditions
    public let diodePreparationLimits: DiodePreparationLimits?
    public let diodeAnalyses: DiodeAnalysisCapabilities?
    public let diodeControl: (any DiodePreparationControlling)?

    public init(
        registry: DeviceRegistry = .standard(),
        operatingConditions: OperatingConditions = .nominal,
        diodePreparationLimits: DiodePreparationLimits? = nil,
        diodeAnalyses: DiodeAnalysisCapabilities? = nil,
        diodeControl: (any DiodePreparationControlling)? = nil
    ) {
        self.registry = registry
        self.operatingConditions = operatingConditions
        self.diodePreparationLimits = diodePreparationLimits; self.diodeAnalyses = diodeAnalyses; self.diodeControl = diodeControl
    }

    public func bind(
        plan: ExecutionPlan,
        instances: [Instance]
    ) throws -> PreparedCircuit {
        try operatingConditions.validateEvaluationEnvironment(plan.ir.evaluationEnvironment)
        guard instances.count == plan.ir.instances.count else {
            throw PreparedCircuitError.boundDeviceCountMismatch(
                expected: plan.ir.instances.count,
                actual: instances.count
            )
        }
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            branchNames: plan.ir.branchNames,
            operatingConditions: operatingConditions,
            stampIndexResolver: { row, column in
                structure.index(row: row, col: column)
            }
        )
        var devices: [any BoundDevice] = []
        devices.reserveCapacity(instances.count)

        for (index, instance) in instances.enumerated() {
            let expected = plan.ir.instances[index]
            guard instance.name == expected.name,
                  instance.typeName == expected.typeName,
                  instance.nodes == expected.nodes,
                  instance.ownedNodes == expected.ownedNodes,
                  instance.model?.name == expected.model?.name,
                  instance.model?.typeName == expected.model?.typeName,
                  instance.opticalNodes == expected.opticalNodes else {
                throw PreparedCircuitError.boundDeviceIdentityMismatch(
                    index: index,
                    expected: expected.name,
                    actual: instance.name
                )
            }
            if instance.typeName == "diode" || instance.diode != nil {
                guard let resolved = instance.diode?.resolved, let basis = expected.diode?.resolved,
                      resolved.instance == basis.instance, resolved.model.declaration == basis.model.declaration,
                      resolved.scope == basis.scope, resolved.invocation == basis.invocation,
                      resolved.profile == basis.profile, resolved.environment == basis.environment else {
                    throw DiodePreparationFailure.identityMismatch
                }
                guard let limits = diodePreparationLimits, let analyses = diodeAnalyses, let control = diodeControl else {
                    throw DiodePreparationFailure.invalidConditions
                }
                let environment = try DiodeNumericPerturbation.environment(resolved)
                let owner = try NativeDiodeDevicePreparer().prepare(.init(resolved: resolved, environment: environment,
                    analyses: analyses, anodeNodeID: instance.nodes[0].id, cathodeNodeID: instance.nodes[1].id),
                    limits: limits, control: control)
                let receipt = owner.receipt
                let prepared = Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                    parameters: instance.parameters, model: instance.model, diode: .prepared(receipt), osdi: instance.osdi,
                    modelConsumption: instance.modelConsumption)
                devices.append(try owner.bind(instance: prepared, context: &context))
                continue
            }
            guard let descriptor = registry.descriptor(for: instance.typeName) else {
                throw AnalysisError.invalidConfiguration(
                    "No device descriptor registered for \(instance.typeName)"
                )
            }
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        return try PreparedCircuit(plan: plan, devices: devices)
    }
}
