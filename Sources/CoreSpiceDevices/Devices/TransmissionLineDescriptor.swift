import CoreSpiceIR

/// Descriptor for an ideal, lossless, fixed-delay transmission line.
public struct TransmissionLineDescriptor: DeviceDescriptor, Sendable {
    public let typeName = "tline"
    public let portNames = ["port1_pos", "port1_neg", "port2_pos", "port2_neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "z0", defaultValue: nil, description: "Characteristic impedance in ohms"),
        ParameterDescriptor(name: "td", defaultValue: nil, description: "Propagation delay in seconds"),
        ParameterDescriptor(name: "f", defaultValue: nil, description: "Reference frequency in hertz"),
        ParameterDescriptor(name: "nl", defaultValue: .real(0.25), description: "Normalized electrical length"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 4,
                got: instance.nodes.count
            )
        }

        let impedance = try requiredRealParameter("z0", from: instance)
        guard impedance.isFinite, impedance > 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "z0",
                message: "Characteristic impedance must be finite and positive"
            )
        }

        let delay = try propagationDelay(from: instance)
        guard delay.isFinite, delay > 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "td",
                message: "Propagation delay must be finite and positive"
            )
        }

        let port1Branch = try context.claimBranch(for: instance, ownedIndex: 0)
        let port2Branch = try context.claimBranch(for: instance, ownedIndex: 1)
        guard let port1BranchIndex = context.branchIndex(port1Branch) else {
            throw DeviceBindingError.missingBranchVariable(device: instance.name, ownedIndex: 0)
        }
        guard let port2BranchIndex = context.branchIndex(port2Branch) else {
            throw DeviceBindingError.missingBranchVariable(device: instance.name, ownedIndex: 1)
        }

        return BoundTransmissionLine(
            instance: instance,
            port1Positive: instance.nodes[0],
            port1Negative: instance.nodes[1],
            port2Positive: instance.nodes[2],
            port2Negative: instance.nodes[3],
            port1Branch: port1Branch,
            port2Branch: port2Branch,
            impedance: impedance,
            delay: delay,
            port1PositiveIndex: context.nodeIndex(instance.nodes[0]),
            port1NegativeIndex: context.nodeIndex(instance.nodes[1]),
            port2PositiveIndex: context.nodeIndex(instance.nodes[2]),
            port2NegativeIndex: context.nodeIndex(instance.nodes[3]),
            port1BranchIndex: port1BranchIndex,
            port2BranchIndex: port2BranchIndex
        )
    }

    private func propagationDelay(from instance: Instance) throws -> Double {
        if let delay = try optionalRealParameter("td", from: instance) {
            if instance.parameters["f"] != nil || instance.parameters["nl"] != nil {
                throw DeviceBindingError.invalidParameterValue(
                    device: instance.name,
                    parameter: "td",
                    message: "Specify either TD or F/NL, not both"
                )
            }
            return delay
        }

        guard let frequency = try optionalRealParameter("f", from: instance) else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "td")
        }
        guard frequency.isFinite, frequency > 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "f",
                message: "Reference frequency must be finite and positive"
            )
        }
        let normalizedLength = try optionalRealParameter("nl", from: instance) ?? 0.25
        guard normalizedLength.isFinite, normalizedLength > 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "nl",
                message: "Normalized electrical length must be finite and positive"
            )
        }
        return normalizedLength / frequency
    }

    private func requiredRealParameter(
        _ name: String,
        from instance: Instance
    ) throws -> Double {
        guard let value = try optionalRealParameter(name, from: instance) else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: name)
        }
        return value
    }

    private func optionalRealParameter(
        _ name: String,
        from instance: Instance
    ) throws -> Double? {
        guard let parameter = instance.parameters[name] else {
            return nil
        }
        guard case .real(let value) = parameter else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: name,
                expected: "real"
            )
        }
        return value
    }
}
