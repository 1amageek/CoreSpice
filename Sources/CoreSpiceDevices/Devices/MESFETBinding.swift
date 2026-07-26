import CoreSpiceIR

enum MESFETBinding {
    private static let supportedKeys: Set<String> = [
        "vto", "alpha", "beta", "lambda", "b", "is", "cgs", "cgd", "pb",
        "fc", "kf", "af", "area", "m", "tnom", "tnom_k",
    ]

    static func bind(
        instance: Instance,
        context: inout BindingContext,
        polarity: MESFETPolarity
    ) throws -> any BoundDevice {
        guard instance.nodes.count == 3 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 3,
                got: instance.nodes.count
            )
        }
        if let unsupported = instance.parameters.keys.first(
            where: { !supportedKeys.contains($0) }
        ) {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: unsupported,
                message: "Unsupported MESFET parameter"
            )
        }

        var parameters = MESFETModelParameters(polarity: polarity)
        if let value = try real("vto", in: instance) { parameters.thresholdVoltage = value }
        if let value = try real("alpha", in: instance) { parameters.alpha = value }
        if let value = try real("beta", in: instance) { parameters.beta = value }
        if let value = try real("lambda", in: instance) { parameters.lambda = value }
        if let value = try real("b", in: instance) { parameters.dopingTailParameter = value }
        if let value = try real("is", in: instance) { parameters.saturationCurrent = value }
        if let value = try real("cgs", in: instance) { parameters.gateSourceCapacitance = value }
        if let value = try real("cgd", in: instance) { parameters.gateDrainCapacitance = value }
        if let value = try real("pb", in: instance) { parameters.gateJunctionPotential = value }
        if let value = try real("fc", in: instance) { parameters.forwardBiasDepletionCoefficient = value }
        if let value = try real("kf", in: instance) { parameters.flickerNoiseCoefficient = value }
        if let value = try real("af", in: instance) { parameters.flickerNoiseExponent = value }
        if let value = try real("area", in: instance) { parameters.area = value }
        if let value = try real("m", in: instance) { parameters.multiplier = value }
        if let value = try real("tnom", in: instance) { parameters.nominalTemperature = value + 273.15 }
        if let value = try real("tnom_k", in: instance) { parameters.nominalTemperature = value }
        parameters.operatingTemperature = context.operatingConditions.temperatureKelvin
        try parameters.validate(device: instance.name)

        let drain = instance.nodes[0]
        let gate = instance.nodes[1]
        let source = instance.nodes[2]
        return BoundMESFET(
            instance: instance,
            drain: drain,
            gate: gate,
            source: source,
            parameters: parameters,
            drainIdx: context.nodeIndex(drain),
            gateIdx: context.nodeIndex(gate),
            sourceIdx: context.nodeIndex(source)
        )
    }

    private static func real(_ key: String, in instance: Instance) throws -> Double? {
        guard let parameter = instance.parameters[key] else {
            return nil
        }
        guard case .real(let value) = parameter else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: key,
                expected: "real"
            )
        }
        return value
    }
}
