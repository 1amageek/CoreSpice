import CoreSpiceIR

/// Descriptor for a two-terminal linear inductor.
///
/// The inductor introduces a branch current variable into the MNA
/// system, similar to a voltage source.
public struct InductorDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "inductor"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "l", defaultValue: nil, description: "Inductance in henrys"),
        ParameterDescriptor(name: "ic", defaultValue: .real(0.0), description: "Initial current through inductor"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let inductance: Double
        if let param = instance.parameters["l"] {
            guard case .real(let l) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "l", expected: "real"
                )
            }
            guard l > 0 else {
                throw DeviceBindingError.invalidParameterValue(
                    device: instance.name, parameter: "l", message: "Inductance must be positive"
                )
            }
            inductance = l
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "l")
        }

        let initialCurrent: Double
        if let icParam = instance.parameters["ic"], case .real(let ic) = icParam {
            initialCurrent = ic
        } else {
            initialCurrent = 0.0
        }

        let branch = context.allocateBranch()

        let posNode = instance.nodes[0]
        let negNode = instance.nodes[1]
        let posIdx = context.nodeIndex(posNode)
        let negIdx = context.nodeIndex(negNode)
        let branchIdx = context.branchIndex(branch)

        // Pre-resolve CSR value indices for O(1) stamping
        let stampPB: Int? = if let i = posIdx, let b = branchIdx { context.stampIndex(row: i, col: b) } else { nil }
        let stampBP: Int? = if let b = branchIdx, let i = posIdx { context.stampIndex(row: b, col: i) } else { nil }
        let stampNB: Int? = if let j = negIdx, let b = branchIdx { context.stampIndex(row: j, col: b) } else { nil }
        let stampBN: Int? = if let b = branchIdx, let j = negIdx { context.stampIndex(row: b, col: j) } else { nil }
        let stampBB: Int? = branchIdx.flatMap { b in context.stampIndex(row: b, col: b) }

        return BoundInductor(
            instance: instance,
            posNode: posNode,
            negNode: negNode,
            inductance: inductance,
            initialCurrent: initialCurrent,
            branch: branch,
            posIdx: posIdx,
            negIdx: negIdx,
            branchIdx: branchIdx,
            stampPB: stampPB,
            stampBP: stampBP,
            stampNB: stampNB,
            stampBN: stampBN,
            stampBB: stampBB
        )
    }
}
