import CoreSpiceIR

/// Descriptor for a P-channel SPICE MESFET.
public struct PMESFETDescriptor: DeviceDescriptor, Sendable {
    public let typeName = "pmesfet"
    public let portNames = ["drain", "gate", "source"]
    public let parameterDescriptors = MESFETParameterSchema.descriptors

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        try MESFETBinding.bind(instance: instance, context: &context, polarity: .pChannel)
    }
}
