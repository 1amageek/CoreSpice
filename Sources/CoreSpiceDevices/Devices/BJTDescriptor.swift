import CoreSpiceIR

/// Descriptor for an NPN bipolar junction transistor.
///
/// The NPN transistor has three terminals: collector, base, and emitter.
/// Current flows from collector to emitter when forward biased.
public struct NPNDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "npn"
    public let portNames = ["collector", "base", "emitter"]

    public let parameterDescriptors: [ParameterDescriptor] = bjtParameterDescriptors

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        try bindBJT(instance: instance, context: &context, polarity: .npn)
    }
}

/// Descriptor for a PNP bipolar junction transistor.
///
/// The PNP transistor has three terminals: collector, base, and emitter.
/// Current flows from emitter to collector when forward biased.
public struct PNPDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "pnp"
    public let portNames = ["collector", "base", "emitter"]

    public let parameterDescriptors: [ParameterDescriptor] = bjtParameterDescriptors

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        try bindBJT(instance: instance, context: &context, polarity: .pnp)
    }
}

// MARK: - Shared Parameter Definitions

private let bjtParameterDescriptors: [ParameterDescriptor] = [
    ParameterDescriptor(name: "is", defaultValue: .real(1e-16), description: "Transport saturation current (A)"),
    ParameterDescriptor(name: "bf", defaultValue: .real(100), description: "Ideal maximum forward beta"),
    ParameterDescriptor(name: "br", defaultValue: .real(1), description: "Ideal maximum reverse beta"),
    ParameterDescriptor(name: "nf", defaultValue: .real(1.0), description: "Forward current emission coefficient"),
    ParameterDescriptor(name: "nr", defaultValue: .real(1.0), description: "Reverse current emission coefficient"),
    ParameterDescriptor(name: "vaf", defaultValue: .real(1e100), description: "Forward Early voltage (V)"),
    ParameterDescriptor(name: "var", defaultValue: .real(1e100), description: "Reverse Early voltage (V)"),
    ParameterDescriptor(name: "rb", defaultValue: .real(0), description: "Base resistance (Ω)"),
    ParameterDescriptor(name: "rc", defaultValue: .real(0), description: "Collector resistance (Ω)"),
    ParameterDescriptor(name: "re", defaultValue: .real(0), description: "Emitter resistance (Ω)"),
    ParameterDescriptor(name: "cje", defaultValue: .real(0), description: "B-E zero-bias depletion capacitance (F)"),
    ParameterDescriptor(name: "cjc", defaultValue: .real(0), description: "B-C zero-bias depletion capacitance (F)"),
    ParameterDescriptor(name: "tf", defaultValue: .real(0), description: "Ideal forward transit time (s)"),
    ParameterDescriptor(name: "tr", defaultValue: .real(0), description: "Ideal reverse transit time (s)"),
    ParameterDescriptor(name: "vje", defaultValue: .real(0.75), description: "B-E junction potential (V)"),
    ParameterDescriptor(name: "vjc", defaultValue: .real(0.75), description: "B-C junction potential (V)"),
    ParameterDescriptor(name: "mje", defaultValue: .real(0.33), description: "B-E grading coefficient"),
    ParameterDescriptor(name: "mjc", defaultValue: .real(0.33), description: "B-C grading coefficient"),
    ParameterDescriptor(name: "tnom", defaultValue: .real(27), description: "Model nominal temperature (°C)"),
    ParameterDescriptor(name: "tnom_k", defaultValue: .real(300.15), description: "Model nominal temperature (K)"),
]

private func extractBJTParameters(
    from instance: Instance,
    polarity: BJTPolarity,
    operatingTemperature: Double,
    circuitNominalTemperature: Double
) throws -> BJTModelParameters {
    let expected = polarity == .npn ? "npn" : "pnp"
    if let model = instance.model, model.typeName != expected {
        throw DeviceBindingError.invalidParameterValue(device: instance.name,
            parameter: "model", message: "BJT model polarity does not match descriptor")
    }
    let supported = Set(bjtParameterDescriptors.map(\.name))
    for source in [instance.model?.parameters ?? [:], instance.parameters] {
        if let unsupported = source.keys.sorted().first(where: { !supported.contains($0) }) {
            throw DeviceBindingError.invalidParameterValue(device: instance.name,
                parameter: unsupported, message: "Unsupported BJT parameter")
        }
        for (key, value) in source {
            guard case .real(let number) = value else {
                throw DeviceBindingError.invalidParameterType(device: instance.name, parameter: key, expected: "real")
            }
            guard number.isFinite else {
                throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: key,
                    message: "Parameter must be finite")
            }
        }
    }
    func supplied(_ key: String) -> ParameterValue? { instance.parameters[key] ?? instance.model?.parameters[key] }
    func extractReal(_ key: String, default defaultValue: Double) throws -> Double {
        guard let value = supplied(key) else { return defaultValue }
        guard case .real(let v) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: key,
                expected: "real"
            )
        }
        return v
    }

    func nominal(in source: [String: ParameterValue]) throws -> Double? {
        let celsius: Double? = if case .real(let v) = source["tnom"] { v + 273.15 } else { nil }
        let kelvin: Double? = if case .real(let v) = source["tnom_k"] { v } else { nil }
        if let celsius, let kelvin, abs(celsius - kelvin) > max(abs(celsius), abs(kelvin)) * 1e-14 {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "tnom",
                message: "BJT nominal-temperature aliases must agree within one source role")
        }
        return kelvin ?? celsius
    }
    let nominalTemperature = try nominal(in: instance.parameters)
        ?? nominal(in: instance.model?.parameters ?? [:]) ?? circuitNominalTemperature
    let params = BJTModelParameters(
        polarity: polarity,
        saturationCurrent: try extractReal("is", default: 1e-16),
        forwardBeta: try extractReal("bf", default: 100),
        reverseBeta: try extractReal("br", default: 1),
        forwardEmissionCoefficient: try extractReal("nf", default: 1.0),
        reverseEmissionCoefficient: try extractReal("nr", default: 1.0),
        forwardEarlyVoltage: try extractReal("vaf", default: 1e100),
        reverseEarlyVoltage: try extractReal("var", default: 1e100),
        baseResistance: try extractReal("rb", default: 0),
        collectorResistance: try extractReal("rc", default: 0),
        emitterResistance: try extractReal("re", default: 0),
        baseEmitterCapacitance: try extractReal("cje", default: 0),
        baseCollectorCapacitance: try extractReal("cjc", default: 0),
        forwardTransitTime: try extractReal("tf", default: 0),
        reverseTransitTime: try extractReal("tr", default: 0),
        baseEmitterPotential: try extractReal("vje", default: 0.75),
        baseCollectorPotential: try extractReal("vjc", default: 0.75),
        baseEmitterGradingCoeff: try extractReal("mje", default: 0.33),
        baseCollectorGradingCoeff: try extractReal("mjc", default: 0.33),
        nominalTemperature: nominalTemperature,
        operatingTemperature: operatingTemperature
    )
    try params.validate(device: instance.name)
    return try BJTTemperaturePreparation.prepare(params, device: instance.name)
}

private func bindBJT(instance: Instance, context: inout BindingContext,
    polarity: BJTPolarity) throws -> any BoundDevice {
    guard instance.nodes.count == 3 else {
        throw DeviceBindingError.portCountMismatch(device: instance.name, expected: 3, got: instance.nodes.count)
    }
    let parameters = try extractBJTParameters(from: instance, polarity: polarity,
        operatingTemperature: context.operatingConditions.temperatureKelvin,
        circuitNominalTemperature: context.operatingConditions.nominalTemperatureKelvin)
    let resistances = [parameters.collectorResistance, parameters.baseResistance, parameters.emitterResistance]
    guard instance.ownedNodes.count == resistances.filter({ $0 > 0 }).count else {
        throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "ownedNodes",
            message: "BJT requires one owned intrinsic node per nonzero rc, rb, re in collector/base/emitter order")
    }
    try context.validateOwnedNodes(for: instance)
    var intrinsic = instance.nodes
    var series: [BJTSeriesElement] = []
    var next = 0
    for terminal in 0..<3 {
        let resistance = resistances[terminal]
        if resistance > 0 {
            let node = instance.ownedNodes[next]; next += 1
            series.append(try BJTSeriesElement(external: instance.nodes[terminal], intrinsic: node,
                resistance: resistance, context: context, device: instance.name))
            intrinsic[terminal] = node
        }
    }
    for node in instance.nodes + intrinsic where node != .ground {
        guard let index = context.nodeIndex(node), (0..<context.matrixDimension).contains(index) else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "nodes",
                message: "BJT terminal is absent from compiled variables")
        }
    }
    let indices = intrinsic.map { context.nodeIndex($0) }
    func stamp(_ row: Int?, _ column: Int?) throws -> Int? {
        guard let row, let column else { return nil }
        let index = context.stampIndex(row: row, col: column)
        guard !context.hasStampIndexResolver || index != nil else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "matrix",
                message: "BJT compiled Jacobian position is absent")
        }
        return index
    }
    let csr = try BJTCSRIndices(cc: stamp(indices[0], indices[0]), cb: stamp(indices[0], indices[1]),
        ce: stamp(indices[0], indices[2]), bc: stamp(indices[1], indices[0]), bb: stamp(indices[1], indices[1]),
        be: stamp(indices[1], indices[2]), ec: stamp(indices[2], indices[0]), eb: stamp(indices[2], indices[1]),
        ee: stamp(indices[2], indices[2]))
    let bound = BoundBJT(instance: instance, collector: intrinsic[0], base: intrinsic[1], emitter: intrinsic[2],
        collectorIdx: indices[0], baseIdx: indices[1], emitterIdx: indices[2], parameters: parameters,
        csrIndices: csr, series: series)
    context.commitValidatedOwnedNodes(for: instance)
    return bound
}
