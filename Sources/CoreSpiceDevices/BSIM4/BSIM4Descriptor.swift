import CoreSpiceIR

/// Native Level 54 descriptor for one explicitly selected MOS polarity.
public struct BSIM4Descriptor: DeviceDescriptor {
    public let typeName: String
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let noisePreparationRequested: Bool
    public let preparationPolicy: BSIM4PreparationPolicy?
    public let parameterDescriptors: [ParameterDescriptor] = []

    public init(pmos: Bool = false, preparationPolicy: BSIM4PreparationPolicy? = nil, noisePreparationRequested: Bool = false) {
        self.noisePreparationRequested = noisePreparationRequested
        typeName = pmos ? "pmos_l54" : "nmos_l54"; self.preparationPolicy = preparationPolicy
    }

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(device: instance.name, expected: 4, got: instance.nodes.count)
        }
        guard let model = instance.model else { throw BSIM4DeviceError.missingModel(instance.name) }
        guard model.typeName == typeName else { throw BSIM4DeviceError.modelTypeMismatch(model.typeName) }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Legacy descriptor callers still cold-prepare at bind.
        // This production descriptor path remains until S4 proves resolved -> single prepare ->
        // consuming bind through the public composition tests; migration is not complete before then.
        let prepared = try BSIM4Preparation.prepare(model: model, instanceParameters: instance.parameters,
            temperature: context.operatingConditions.temperatureKelvin, policy: preparationPolicy, noisePreparationRequested: noisePreparationRequested)
        return try prepared.bind(instance: instance, context: &context)
    }
}
