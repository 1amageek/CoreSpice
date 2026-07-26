import CoreSpiceIR

/// Descriptor for an N-channel SPICE MESFET.
public struct NMESFETDescriptor: DeviceDescriptor, Sendable {
    public let typeName = "nmesfet"
    public let portNames = ["drain", "gate", "source"]
    public let parameterDescriptors = MESFETParameterSchema.descriptors

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        try MESFETBinding.bind(instance: instance, context: &context, polarity: .nChannel)
    }
}
