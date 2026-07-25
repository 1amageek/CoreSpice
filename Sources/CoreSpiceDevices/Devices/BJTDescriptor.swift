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
        guard instance.nodes.count == 3 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 3,
                got: instance.nodes.count
            )
        }

        let params = try extractBJTParameters(
            from: instance,
            polarity: .npn,
            operatingTemperature: context.operatingConditions.temperatureKelvin
        )

        let collectorNode = instance.nodes[0]
        let baseNode = instance.nodes[1]
        let emitterNode = instance.nodes[2]
        let cIdx = context.nodeIndex(collectorNode)
        let bIdx = context.nodeIndex(baseNode)
        let eIdx = context.nodeIndex(emitterNode)

        // Pre-resolve CSR value indices for O(1) stamping (3x3 = 9 positions)
        let csrIndices = BJTCSRIndices(
            cc: cIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            cb: cIdx.flatMap { c in bIdx.flatMap { context.stampIndex(row: c, col: $0) } },
            ce: cIdx.flatMap { c in eIdx.flatMap { context.stampIndex(row: c, col: $0) } },
            bc: bIdx.flatMap { b in cIdx.flatMap { context.stampIndex(row: b, col: $0) } },
            bb: bIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            be: bIdx.flatMap { b in eIdx.flatMap { context.stampIndex(row: b, col: $0) } },
            ec: eIdx.flatMap { e in cIdx.flatMap { context.stampIndex(row: e, col: $0) } },
            eb: eIdx.flatMap { e in bIdx.flatMap { context.stampIndex(row: e, col: $0) } },
            ee: eIdx.flatMap { context.stampIndex(row: $0, col: $0) }
        )

        return BoundBJT(
            instance: instance,
            collector: collectorNode,
            base: baseNode,
            emitter: emitterNode,
            collectorIdx: cIdx,
            baseIdx: bIdx,
            emitterIdx: eIdx,
            parameters: params,
            csrIndices: csrIndices
        )
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
        guard instance.nodes.count == 3 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 3,
                got: instance.nodes.count
            )
        }

        let params = try extractBJTParameters(
            from: instance,
            polarity: .pnp,
            operatingTemperature: context.operatingConditions.temperatureKelvin
        )

        let collectorNode = instance.nodes[0]
        let baseNode = instance.nodes[1]
        let emitterNode = instance.nodes[2]
        let cIdx = context.nodeIndex(collectorNode)
        let bIdx = context.nodeIndex(baseNode)
        let eIdx = context.nodeIndex(emitterNode)

        // Pre-resolve CSR value indices for O(1) stamping (3x3 = 9 positions)
        let csrIndices = BJTCSRIndices(
            cc: cIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            cb: cIdx.flatMap { c in bIdx.flatMap { context.stampIndex(row: c, col: $0) } },
            ce: cIdx.flatMap { c in eIdx.flatMap { context.stampIndex(row: c, col: $0) } },
            bc: bIdx.flatMap { b in cIdx.flatMap { context.stampIndex(row: b, col: $0) } },
            bb: bIdx.flatMap { context.stampIndex(row: $0, col: $0) },
            be: bIdx.flatMap { b in eIdx.flatMap { context.stampIndex(row: b, col: $0) } },
            ec: eIdx.flatMap { e in cIdx.flatMap { context.stampIndex(row: e, col: $0) } },
            eb: eIdx.flatMap { e in bIdx.flatMap { context.stampIndex(row: e, col: $0) } },
            ee: eIdx.flatMap { context.stampIndex(row: $0, col: $0) }
        )

        return BoundBJT(
            instance: instance,
            collector: collectorNode,
            base: baseNode,
            emitter: emitterNode,
            collectorIdx: cIdx,
            baseIdx: bIdx,
            emitterIdx: eIdx,
            parameters: params,
            csrIndices: csrIndices
        )
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
    operatingTemperature: Double
) throws -> BJTModelParameters {
    func extractReal(_ key: String, default defaultValue: Double) throws -> Double {
        guard let value = instance.parameters[key] else { return defaultValue }
        guard case .real(let v) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: key,
                expected: "real"
            )
        }
        return v
    }

    let nominalTemperature = try instance.parameters["tnom_k"].map {
        guard case .real(let value) = $0 else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: "tnom_k",
                expected: "real"
            )
        }
        return value
    } ?? (try extractReal("tnom", default: 27) + 273.15)
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
    return params
}
