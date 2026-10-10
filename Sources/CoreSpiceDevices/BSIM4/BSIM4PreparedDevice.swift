import CoreSpiceCompactModels
import CoreSpiceIR
import CoreSpiceMOSContracts

/// One fresh evaluator, transferable once into the bound device.
public struct BSIM4PreparedDevice: ~Copyable, Sendable {
    private let evaluator: BSIM4Evaluator
    public let multiplier: Double
    public let initialConditions: SIMD3<Double>?
    package var diagnostics: [BSIM4Diagnostic] { evaluator.diagnostics }
    package var preparationTemporaryBytes: UInt64 { evaluator.preparationTemporaryBytes }
    package var diagnosticStorageBytes: UInt64 { evaluator.diagnosticStorageBytes }
    package var preparationWorkUnits: UInt64 { evaluator.preparationWorkUnits }
    public var topology: BSIM4Topology { evaluator.topology }
    public var auxiliaryNodeCount: Int { topology.nodeCount - 4 }
    package let preparationIdentity: MOSPreparationIdentity?
    public let policy: BSIM4PreparationPolicy

    init(configuration: BSIM4Configuration, multiplier: Double,
         initialConditions: SIMD3<Double>?, preparationIdentity: MOSPreparationIdentity? = nil, policy: BSIM4PreparationPolicy,
         preparationLimits: MOSPreparationLimits? = nil, preparationControl: (any MOSPreparationControlling)? = nil) throws {
        if let preparationLimits {
            evaluator = try BSIM4Evaluator(configuration: configuration,
                preparationLimits: preparationLimits, preparationControl: preparationControl)
        } else { evaluator = try BSIM4Evaluator(configuration: configuration) }
        self.multiplier = multiplier
        self.initialConditions = initialConditions
        self.preparationIdentity = preparationIdentity
        self.policy = policy
    }

    consuming func bind(instance: Instance, context: inout BindingContext, control: (any MOSPreparationControlling)? = nil) throws -> any BoundDevice {
        guard instance.nodes.count == 4, instance.ownedNodes.count == auxiliaryNodeCount else {
            throw BSIM4DeviceError.invalidAuxiliaryTopology(instance.name)
        }
        try context.validateOwnedNodes(for: instance)
        var indices = SIMD16<Int>(repeating: -1)
        for index in 0..<topology.nodeCount {
            let node = index < 4 ? instance.nodes[index] : instance.ownedNodes[index - 4]
            if node != .ground {
                guard let matrixIndex = context.nodeIndex(node), (0..<context.matrixDimension).contains(matrixIndex) else {
                    throw BSIM4DeviceError.invalidAuxiliaryTopology(instance.name)
                }
                indices[index + 1] = matrixIndex
            }
        }
        var csrIndices = BSIM4StampMapping()
        for row in 1...topology.nodeCount where indices[row] >= 0 {
            for column in 1...topology.nodeCount where indices[column] >= 0 {
                guard let slot = context.stampIndex(row: indices[row], col: indices[column]), slot >= 0 else {
                    throw BSIM4DeviceError.invalidAuxiliaryTopology(instance.name)
                }
                csrIndices.set(row * 16 + column, slot)
            }
        }
        let bound = try BoundBSIM4(instance: instance, evaluator: evaluator,
            multiplier: multiplier, initialConditions: initialConditions, policy: policy,
            indices: indices, csrIndices: csrIndices)
        try control?.checkCancellation()
        context.commitValidatedOwnedNodes(for: instance)
        return bound
    }
}
