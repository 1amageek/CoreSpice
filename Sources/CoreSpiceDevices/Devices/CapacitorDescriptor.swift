import CoreSpiceIR

/// Descriptor for a two-terminal linear capacitor.
public struct CapacitorDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "capacitor"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "c", defaultValue: nil, description: "Capacitance in farads"),
        ParameterDescriptor(name: "ic", defaultValue: .real(0.0), description: "Initial voltage across capacitor"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let capacitance: Double
        if let param = instance.parameters["c"] {
            guard case .real(let c) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "c", expected: "real"
                )
            }
            guard c > 0 else {
                throw DeviceBindingError.invalidParameterValue(
                    device: instance.name, parameter: "c", message: "Capacitance must be positive"
                )
            }
            capacitance = c
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "c")
        }

        let initialVoltage: Double
        if let icParam = instance.parameters["ic"], case .real(let ic) = icParam {
            initialVoltage = ic
        } else {
            initialVoltage = 0.0
        }

        let posNode = instance.nodes[0]
        let negNode = instance.nodes[1]
        let posIdx = context.nodeIndex(posNode)
        let negIdx = context.nodeIndex(negNode)

        // Pre-resolve CSR value indices for O(1) stamping
        let stampPP = posIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampNN = negIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampPN: Int? = if let i = posIdx, let j = negIdx { context.stampIndex(row: i, col: j) } else { nil }
        let stampNP: Int? = if let i = negIdx, let j = posIdx { context.stampIndex(row: i, col: j) } else { nil }

        return BoundCapacitor(
            instance: instance,
            posNode: posNode,
            negNode: negNode,
            capacitance: capacitance,
            initialVoltage: initialVoltage,
            posIdx: posIdx,
            negIdx: negIdx,
            stampPP: stampPP,
            stampNN: stampNN,
            stampPN: stampPN,
            stampNP: stampNP
        )
    }
}
