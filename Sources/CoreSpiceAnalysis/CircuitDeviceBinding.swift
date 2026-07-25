import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR

/// Binds a complete circuit instance set without owning compilation or analysis.
public protocol CircuitDeviceBinding: Sendable {
    func bind(
        plan: ExecutionPlan,
        instances: [Instance]
    ) throws -> PreparedCircuit
}

/// Production device-binding service backed by an injected registry.
public struct StandardCircuitDeviceBinding: CircuitDeviceBinding, Sendable {
    public let registry: DeviceRegistry
    public let operatingConditions: OperatingConditions

    public init(
        registry: DeviceRegistry = .standard(),
        operatingConditions: OperatingConditions = .nominal
    ) {
        self.registry = registry
        self.operatingConditions = operatingConditions
    }

    public func bind(
        plan: ExecutionPlan,
        instances: [Instance]
    ) throws -> PreparedCircuit {
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
                  instance.opticalNodes == expected.opticalNodes else {
                throw PreparedCircuitError.boundDeviceIdentityMismatch(
                    index: index,
                    expected: expected.name,
                    actual: instance.name
                )
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
