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

        let params = extractBJTParameters(from: instance, polarity: .npn)

        let collectorNode = instance.nodes[0]
        let baseNode = instance.nodes[1]
        let emitterNode = instance.nodes[2]

        return BoundBJT(
            instance: instance,
            collector: collectorNode,
            base: baseNode,
            emitter: emitterNode,
            collectorIdx: context.nodeIndex(collectorNode),
            baseIdx: context.nodeIndex(baseNode),
            emitterIdx: context.nodeIndex(emitterNode),
            parameters: params
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

        let params = extractBJTParameters(from: instance, polarity: .pnp)

        let collectorNode = instance.nodes[0]
        let baseNode = instance.nodes[1]
        let emitterNode = instance.nodes[2]

        return BoundBJT(
            instance: instance,
            collector: collectorNode,
            base: baseNode,
            emitter: emitterNode,
            collectorIdx: context.nodeIndex(collectorNode),
            baseIdx: context.nodeIndex(baseNode),
            emitterIdx: context.nodeIndex(emitterNode),
            parameters: params
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
]

private func extractBJTParameters(from instance: Instance, polarity: BJTPolarity) -> BJTModelParameters {
    func extractReal(_ key: String, default defaultValue: Double) -> Double {
        guard case .real(let v) = instance.parameters[key] else { return defaultValue }
        return v
    }

    return BJTModelParameters(
        polarity: polarity,
        saturationCurrent: extractReal("is", default: 1e-16),
        forwardBeta: extractReal("bf", default: 100),
        reverseBeta: extractReal("br", default: 1),
        forwardEmissionCoefficient: extractReal("nf", default: 1.0),
        reverseEmissionCoefficient: extractReal("nr", default: 1.0),
        forwardEarlyVoltage: extractReal("vaf", default: 1e100),
        reverseEarlyVoltage: extractReal("var", default: 1e100),
        baseResistance: extractReal("rb", default: 0),
        collectorResistance: extractReal("rc", default: 0),
        emitterResistance: extractReal("re", default: 0),
        baseEmitterCapacitance: extractReal("cje", default: 0),
        baseCollectorCapacitance: extractReal("cjc", default: 0),
        forwardTransitTime: extractReal("tf", default: 0),
        reverseTransitTime: extractReal("tr", default: 0),
        baseEmitterPotential: extractReal("vje", default: 0.75),
        baseCollectorPotential: extractReal("vjc", default: 0.75),
        baseEmitterGradingCoeff: extractReal("mje", default: 0.33),
        baseCollectorGradingCoeff: extractReal("mjc", default: 0.33)
    )
}
