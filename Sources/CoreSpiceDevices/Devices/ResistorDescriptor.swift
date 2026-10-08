import CoreSpiceIR

/// Descriptor for a two-terminal static semiconductor resistor.
public struct ResistorDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "resistor"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "r", defaultValue: nil, description: "Resistance in ohms"),
        ParameterDescriptor(name: "ac", defaultValue: nil, description: "Independent AC resistance in ohms"),
        ParameterDescriptor(name: "l", defaultValue: nil, description: "Instance length in meters after document scale"),
        ParameterDescriptor(name: "w", defaultValue: nil, description: "Instance width in meters after document scale"),
        ParameterDescriptor(name: "temp", defaultValue: nil, description: "Absolute instance temperature in Celsius"),
        ParameterDescriptor(name: "dtemp", defaultValue: nil, description: "Instance temperature offset in Kelvin"),
        ParameterDescriptor(name: "tc1", defaultValue: nil, description: "Instance linear temperature coefficient"),
        ParameterDescriptor(name: "tc2", defaultValue: nil, description: "Instance quadratic temperature coefficient"),
        ParameterDescriptor(name: "tce", defaultValue: nil, description: "Instance exponential temperature coefficient"),
        ParameterDescriptor(name: "m", defaultValue: nil, description: "Positive parallel multiplicity"),
        ParameterDescriptor(name: "scale", defaultValue: nil, description: "Positive resistance scale distinct from document geometry scale"),
        ParameterDescriptor(name: "noisy", defaultValue: nil, description: "Noise enabled (1) or disabled (0)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let parameters = try ResistorPreparation.prepare(instance: instance, conditions: context.operatingConditions)

        let posNode = instance.nodes[0]
        let negNode = instance.nodes[1]
        let posIdx = context.nodeIndex(posNode)
        let negIdx = context.nodeIndex(negNode)

        // Pre-resolve CSR value indices for O(1) stamping
        let stampPP = posIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampNN = negIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampPN: Int? = if let i = posIdx, let j = negIdx { context.stampIndex(row: i, col: j) } else { nil }
        let stampNP: Int? = if let i = negIdx, let j = posIdx { context.stampIndex(row: i, col: j) } else { nil }

        return BoundResistor(
            instance: instance,
            posNode: posNode,
            negNode: negNode,
            parameters: parameters,
            posIdx: posIdx,
            negIdx: negIdx,
            stampPP: stampPP,
            stampNN: stampNN,
            stampPN: stampPN,
            stampNP: stampNP
        )
    }
}
