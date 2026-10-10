import CoreSpiceIR

/// Native Level 49 descriptor for one explicitly selected MOS polarity.
public struct BSIM3Descriptor: DeviceDescriptor {
    public let typeName: String
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let parameterDescriptors: [ParameterDescriptor] = []

    public init(pmos: Bool = false) { typeName = pmos ? "pmos_l49" : "nmos_l49" }

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(device: instance.name, expected: 4, got: instance.nodes.count)
        }
        guard let model = instance.model else { throw BSIM3DeviceError.missingModel(instance.name) }
        guard model.typeName == typeName else { throw BSIM3DeviceError.modelTypeMismatch(model.typeName) }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Legacy descriptor callers still cold-prepare at bind.
        // This production descriptor path remains until S4 proves resolved -> single prepare ->
        // consuming bind through the public composition tests; migration is not complete before then.
        let prepared = try BSIM3Preparation.prepare(model: model, instanceParameters: instance.parameters,
            temperature: context.operatingConditions.temperatureKelvin)
        return try prepared.bind(instance: instance, context: &context)
    }
}
