import CoreSpiceIR

/// Native Level 54 descriptor for one explicitly selected MOS polarity.
public struct BSIM4Descriptor: DeviceDescriptor {
    public let typeName: String
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let noisePreparationRequested: Bool
    public let preparationPolicy: BSIM4PreparationPolicy?
    public let parameterDescriptors: [ParameterDescriptor] = []

    public init(pmos: Bool = false, preparationPolicy: BSIM4PreparationPolicy? = nil, noisePreparationRequested: Bool = false) {
        self.noisePreparationRequested = noisePreparationRequested
        typeName = pmos ? "pmos_l54" : "nmos_l54"; self.preparationPolicy = preparationPolicy
    }

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(device: instance.name, expected: 4, got: instance.nodes.count)
        }
        guard let model = instance.model else { throw BSIM4DeviceError.missingModel(instance.name) }
        guard model.typeName == typeName else { throw BSIM4DeviceError.modelTypeMismatch(model.typeName) }
        let prepared = try BSIM4Preparation.prepare(model: model, instanceParameters: instance.parameters,
            temperature: context.operatingConditions.temperatureKelvin, policy: preparationPolicy, noisePreparationRequested: noisePreparationRequested)
        guard instance.ownedNodes.count == prepared.auxiliaryNodeCount else {
            throw BSIM4DeviceError.invalidAuxiliaryTopology(instance.name)
        }
        try context.claimOwnedNodes(for: instance)
        var indices = SIMD16<Int>(repeating: -1)
        let localNodes = instance.nodes + instance.ownedNodes
        for (index, node) in localNodes.enumerated() where node != .ground {
            guard let matrixIndex = context.nodeIndex(node), (0..<context.matrixDimension).contains(matrixIndex) else {
                throw BSIM4DeviceError.invalidAuxiliaryTopology(instance.name)
            }
            indices[index + 1] = matrixIndex
        }
        var csrIndices = BSIM4StampMapping()
        for row in 1...prepared.evaluator.topology.nodeCount where indices[row] >= 0 {
            for column in 1...prepared.evaluator.topology.nodeCount where indices[column] >= 0 {
                if let index = context.stampIndex(row: indices[row], col: indices[column]) {
                    csrIndices.set(row * 16 + column, index)
                }
            }
        }
        return try BoundBSIM4(instance: instance, prepared: prepared, indices: indices, csrIndices: csrIndices)
    }
}
