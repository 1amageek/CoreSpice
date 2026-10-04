import CoreSpiceIR

/// Native Level 49 descriptor for one explicitly selected MOS polarity.
public struct BSIM3Descriptor: DeviceDescriptor {
    public let typeName: String
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let parameterDescriptors: [ParameterDescriptor] = []

    public init(pmos: Bool = false) { typeName = pmos ? "pmos_l49" : "nmos_l49" }

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(device: instance.name, expected: 4, got: instance.nodes.count)
        }
        guard let model = instance.model else { throw BSIM3DeviceError.missingModel(instance.name) }
        guard model.typeName == typeName else { throw BSIM3DeviceError.modelTypeMismatch(model.typeName) }
        let prepared = try BSIM3Preparation.prepare(model: model, instanceParameters: instance.parameters,
            temperature: context.operatingConditions.temperatureKelvin)
        guard instance.ownedNodes.count == prepared.auxiliaryNodeCount else {
            throw BSIM3DeviceError.invalidAuxiliaryTopology(instance.name)
        }
        try context.claimOwnedNodes(for: instance)
        var indices = SIMD8<Int>(repeating: -1)
        let localNodes = instance.nodes + instance.ownedNodes
        for (index, node) in localNodes.enumerated() where node != .ground {
            guard let matrixIndex = context.nodeIndex(node), (0..<context.matrixDimension).contains(matrixIndex) else {
                throw BSIM3DeviceError.invalidAuxiliaryTopology(instance.name)
            }
            indices[index + 1] = matrixIndex
        }
        var csrIndices = SIMD64<Int>(repeating: -1)
        for row in 1...prepared.evaluator.topology.nodeCount where indices[row] >= 0 {
            for column in 1...prepared.evaluator.topology.nodeCount where indices[column] >= 0 {
                if let index = context.stampIndex(row: indices[row], col: indices[column]) {
                    csrIndices[row * 8 + column] = index
                }
            }
        }
        return try BoundBSIM3(instance: instance, prepared: prepared, indices: indices, csrIndices: csrIndices)
    }
}
