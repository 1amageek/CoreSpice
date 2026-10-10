import CoreSpiceCompactModels
import CoreSpiceIR
import CoreSpiceMOSContracts

/// One fresh evaluator, transferable once into the bound device.
public struct BSIM3PreparedDevice: ~Copyable, Sendable {
    private let evaluator: BSIM3Evaluator
    public let multiplier: Double
    public let initialConditions: SIMD3<Double>?
    package var diagnostics: [BSIM3Diagnostic] { evaluator.diagnostics }
    package var preparationTemporaryBytes: UInt64 { evaluator.preparationTemporaryBytes }
    package var diagnosticStorageBytes: UInt64 { evaluator.diagnosticStorageBytes }
    package var preparationWorkUnits: UInt64 { evaluator.preparationWorkUnits }
    public var topology: BSIM3Topology { evaluator.topology }
    public var auxiliaryNodeCount: Int { topology.nodeCount - 4 }
    package let preparationIdentity: MOSPreparationIdentity?

    init(configuration: BSIM3Configuration, multiplier: Double,
         initialConditions: SIMD3<Double>?, preparationIdentity: MOSPreparationIdentity? = nil,
         preparationLimits: MOSPreparationLimits? = nil, preparationControl: (any MOSPreparationControlling)? = nil) throws {
        if let preparationLimits {
            evaluator = try BSIM3Evaluator(configuration: configuration,
                preparationLimits: preparationLimits, preparationControl: preparationControl)
        } else { evaluator = try BSIM3Evaluator(configuration: configuration) }
        self.multiplier = multiplier
        self.initialConditions = initialConditions
        self.preparationIdentity = preparationIdentity
    }

    consuming func bind(instance: Instance, context: inout BindingContext, control: (any MOSPreparationControlling)? = nil) throws -> any BoundDevice {
        guard instance.nodes.count == 4, instance.ownedNodes.count == auxiliaryNodeCount else {
            throw BSIM3DeviceError.invalidAuxiliaryTopology(instance.name)
        }
        try context.validateOwnedNodes(for: instance)
        var indices = SIMD8<Int>(repeating: -1)
        for index in 0..<topology.nodeCount {
            let node = index < 4 ? instance.nodes[index] : instance.ownedNodes[index - 4]
            if node != .ground {
                guard let matrixIndex = context.nodeIndex(node), (0..<context.matrixDimension).contains(matrixIndex) else {
                    throw BSIM3DeviceError.invalidAuxiliaryTopology(instance.name)
                }
                indices[index + 1] = matrixIndex
            }
        }
        var csrIndices = SIMD64<Int>(repeating: -1)
        for row in 1...topology.nodeCount where indices[row] >= 0 {
            for column in 1...topology.nodeCount where indices[column] >= 0 {
                guard let slot = context.stampIndex(row: indices[row], col: indices[column]), slot >= 0 else {
                    throw BSIM3DeviceError.invalidAuxiliaryTopology(instance.name)
                }
                csrIndices[row * 8 + column] = slot
            }
        }
        let bound = try BoundBSIM3(instance: instance, evaluator: evaluator,
            multiplier: multiplier, initialConditions: initialConditions,
            indices: indices, csrIndices: csrIndices)
        try control?.checkCancellation()
        context.commitValidatedOwnedNodes(for: instance)
        return bound
    }
}
