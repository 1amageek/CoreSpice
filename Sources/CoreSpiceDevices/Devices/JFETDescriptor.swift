import CoreSpiceIR

/// Descriptor for an N-channel junction field-effect transistor.
public struct NJFETDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "njfet"
    public let portNames = ["drain", "gate", "source"]
    public let parameterDescriptors: [ParameterDescriptor] = jfetParameterDescriptors(defaultVTO: -2.0)

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        try bindJFET(instance: instance, context: &context, polarity: .nChannel)
    }
}

/// Descriptor for a P-channel junction field-effect transistor.
public struct PJFETDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "pjfet"
    public let portNames = ["drain", "gate", "source"]
    public let parameterDescriptors: [ParameterDescriptor] = jfetParameterDescriptors(defaultVTO: -2.0)

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        try bindJFET(instance: instance, context: &context, polarity: .pChannel)
    }
}

private func jfetParameterDescriptors(defaultVTO: Double) -> [ParameterDescriptor] {
    [
        ParameterDescriptor(name: "vto", defaultValue: .real(defaultVTO), description: "Threshold/pinch-off voltage (V)"),
        ParameterDescriptor(name: "beta", defaultValue: .real(1e-4), description: "Transconductance coefficient (A/V^2)"),
        ParameterDescriptor(name: "lambda", defaultValue: .real(0), description: "Channel-length modulation coefficient (1/V)"),
        ParameterDescriptor(name: "is", defaultValue: .real(1e-14), description: "Gate junction saturation current (A)"),
        ParameterDescriptor(name: "n", defaultValue: .real(1), description: "Gate junction emission coefficient"),
        ParameterDescriptor(name: "cgs", defaultValue: .real(0), description: "Zero-bias gate-source capacitance (F)"),
        ParameterDescriptor(name: "cgd", defaultValue: .real(0), description: "Zero-bias gate-drain capacitance (F)"),
        ParameterDescriptor(name: "pb", defaultValue: .real(1), description: "Gate junction built-in potential (V)"),
        ParameterDescriptor(name: "m", defaultValue: .real(0.5), description: "Gate junction grading coefficient"),
        ParameterDescriptor(name: "fc", defaultValue: .real(0.5), description: "Forward-bias depletion capacitance coefficient"),
        ParameterDescriptor(name: "kf", defaultValue: .real(0), description: "Flicker noise coefficient"),
        ParameterDescriptor(name: "af", defaultValue: .real(1), description: "Flicker noise current exponent"),
        ParameterDescriptor(name: "area", defaultValue: .real(1), description: "Instance area multiplier"),
        ParameterDescriptor(name: "tnom", defaultValue: .real(27), description: "Nominal temperature (°C, SPICE convention)"),
        ParameterDescriptor(name: "tnom_k", defaultValue: .real(300.15), description: "Nominal temperature (K)")
    ]
}

private func bindJFET(
    instance: Instance,
    context: inout BindingContext,
    polarity: JFETPolarity
) throws -> any BoundDevice {
    guard instance.nodes.count == 3 else {
        throw DeviceBindingError.portCountMismatch(
            device: instance.name,
            expected: 3,
            got: instance.nodes.count
        )
    }

    let params = try extractJFETParameters(
        from: instance,
        polarity: polarity,
        operatingTemperature: context.operatingConditions.temperatureKelvin
    )
    let drainNode = instance.nodes[0]
    let gateNode = instance.nodes[1]
    let sourceNode = instance.nodes[2]
    let drainIdx = context.nodeIndex(drainNode)
    let gateIdx = context.nodeIndex(gateNode)
    let sourceIdx = context.nodeIndex(sourceNode)

    return BoundJFET(
        instance: instance,
        drain: drainNode,
        gate: gateNode,
        source: sourceNode,
        parameters: params,
        drainIdx: drainIdx,
        gateIdx: gateIdx,
        sourceIdx: sourceIdx
    )
}

private func extractJFETParameters(
    from instance: Instance,
    polarity: JFETPolarity,
    operatingTemperature: Double
) throws -> JFETModelParameters {
    let supportedKeys: Set<String> = [
        "vto", "beta", "b", "lambda", "is", "n", "cgs", "cgd", "pb", "m",
        "fc", "kf", "af", "area", "tnom", "tnom_k"
    ]
    if let unsupported = instance.parameters.keys.first(where: { !supportedKeys.contains($0) }) {
        throw DeviceBindingError.invalidParameterValue(
            device: instance.name,
            parameter: unsupported,
            message: "Unsupported JFET parameter"
        )
    }

    func extractReal(_ key: String) throws -> Double? {
        guard let value = instance.parameters[key] else { return nil }
        guard case .real(let real) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: key,
                expected: "real"
            )
        }
        return real
    }

    var params = JFETModelParameters(polarity: polarity)
    if let value = try extractReal("vto") { params.thresholdVoltage = value }
    if let value = try extractReal("beta") { params.beta = value }
    if let value = try extractReal("b") { params.beta = value }
    if let value = try extractReal("lambda") { params.lambda = value }
    if let value = try extractReal("is") { params.saturationCurrent = value }
    if let value = try extractReal("n") { params.emissionCoefficient = value }
    if let value = try extractReal("cgs") { params.gateSourceCapacitance = value }
    if let value = try extractReal("cgd") { params.gateDrainCapacitance = value }
    if let value = try extractReal("pb") { params.gateJunctionPotential = value }
    if let value = try extractReal("m") { params.gateJunctionGradingCoefficient = value }
    if let value = try extractReal("fc") { params.forwardBiasDepletionCoefficient = value }
    if let value = try extractReal("kf") { params.flickerNoiseCoefficient = value }
    if let value = try extractReal("af") { params.flickerNoiseExponent = value }
    if let value = try extractReal("area") { params.area = value }
    if let value = try extractReal("tnom") { params.nominalTemperature = value + 273.15 }
    if let value = try extractReal("tnom_k") { params.nominalTemperature = value }
    params.operatingTemperature = operatingTemperature
    try params.validate(device: instance.name)
    return params
}
