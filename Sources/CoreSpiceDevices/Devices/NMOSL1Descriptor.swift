import CoreSpiceIR

/// Descriptor for an NMOS Level 1 MOSFET (Shichman-Hodges model).
///
/// Four ports: drain, gate, source, bulk. Body effect is modeled
/// via `gamma` and `phi` parameters using the bulk-source voltage.
public struct NMOSL1Descriptor: DeviceDescriptor, Sendable {

    public let typeName = "nmos_l1"
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "w", defaultValue: .real(10e-6), description: "Channel width (m)"),
        ParameterDescriptor(name: "l", defaultValue: .real(1e-6), description: "Channel length (m)"),
        ParameterDescriptor(name: "vto", defaultValue: .real(0.7), description: "Threshold voltage (V)"),
        ParameterDescriptor(name: "kp", defaultValue: .real(110e-6), description: "Transconductance parameter (A/V^2)"),
        ParameterDescriptor(name: "gamma", defaultValue: .real(0.4), description: "Body effect coefficient (V^0.5)"),
        ParameterDescriptor(name: "phi", defaultValue: .real(0.65), description: "Surface potential (V)"),
        ParameterDescriptor(name: "lambda", defaultValue: .real(0.04), description: "Channel-length modulation (1/V)"),
        ParameterDescriptor(name: "tox", defaultValue: .real(100e-9), description: "Gate oxide thickness (m)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let params = try extractModelParameters(from: instance)

        let drainNode = instance.nodes[0]
        let gateNode = instance.nodes[1]
        let sourceNode = instance.nodes[2]
        let bulkNode = instance.nodes[3]

        return BoundNMOSL1(
            instance: instance,
            drain: drainNode,
            gate: gateNode,
            source: sourceNode,
            bulk: bulkNode,
            parameters: params,
            drainIdx: context.nodeIndex(drainNode),
            gateIdx: context.nodeIndex(gateNode),
            sourceIdx: context.nodeIndex(sourceNode),
            bulkIdx: context.nodeIndex(bulkNode)
        )
    }

    private func extractModelParameters(from instance: Instance) throws -> MOSFETModelParameters {
        var params = MOSFETModelParameters()

        if let p = instance.parameters["w"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "w", expected: "real"
                )
            }
            params.w = v
        }
        if let p = instance.parameters["l"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "l", expected: "real"
                )
            }
            params.l = v
        }
        if let p = instance.parameters["vto"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "vto", expected: "real"
                )
            }
            params.vto = v
        }
        if let p = instance.parameters["kp"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "kp", expected: "real"
                )
            }
            params.kp = v
        }
        if let p = instance.parameters["gamma"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "gamma", expected: "real"
                )
            }
            params.gamma = v
        }
        if let p = instance.parameters["phi"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "phi", expected: "real"
                )
            }
            params.phi = v
        }
        if let p = instance.parameters["lambda"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "lambda", expected: "real"
                )
            }
            params.lambda = v
        }
        if let p = instance.parameters["tox"] {
            guard case .real(let v) = p else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "tox", expected: "real"
                )
            }
            params.tox = v
        }

        return params
    }
}
