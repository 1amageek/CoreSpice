import CoreSpiceIR

/// Descriptor for an independent voltage source.
///
/// Supports DC voltage and time-varying waveforms for transient analysis.
/// Waveform types:
/// - DC: `v` parameter only
/// - Pulse: `v1`, `v2`, `td`, `tr`, `tf`, `pw`, `per` parameters
/// - Sine: `vo`, `va`, `freq`, `td`, `phase` parameters
/// - PWL: `pwl` parameter as array of time-value pairs
public struct VoltageSourceDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "vsource"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "pwl", defaultValue: nil, description: "Alternating finite time/value pairs"),
        ParameterDescriptor(name: "ac", defaultValue: .real(0), description: "AC small-signal magnitude"),
        ParameterDescriptor(name: "acphase", defaultValue: .real(0), description: "AC phase in degrees"),
        // DC
        ParameterDescriptor(name: "v", defaultValue: .real(0.0), description: "DC voltage in volts"),
        // Pulse waveform
        ParameterDescriptor(name: "v1", defaultValue: nil, description: "Initial pulse value"),
        ParameterDescriptor(name: "v2", defaultValue: nil, description: "Pulsed value"),
        ParameterDescriptor(name: "td", defaultValue: .real(0.0), description: "Delay time"),
        ParameterDescriptor(name: "tr", defaultValue: .real(0.0), description: "Rise time"),
        ParameterDescriptor(name: "tf", defaultValue: .real(0.0), description: "Fall time"),
        ParameterDescriptor(name: "pw", defaultValue: .real(0.0), description: "Pulse width"),
        ParameterDescriptor(name: "per", defaultValue: .real(0.0), description: "Period"),
        // Sine waveform
        ParameterDescriptor(name: "vo", defaultValue: nil, description: "Offset voltage"),
        ParameterDescriptor(name: "va", defaultValue: nil, description: "Amplitude"),
        ParameterDescriptor(name: "freq", defaultValue: nil, description: "Frequency in Hz"),
        ParameterDescriptor(name: "phase", defaultValue: .real(0.0), description: "Phase in degrees"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let waveform = try IndependentSourceWaveformParser.parse(instance, current: false)
        let dcVoltage = waveform.dcValue
        let acMagnitude = try IndependentSourceWaveformParser.real("ac", instance: instance, defaultValue: 0)

        let branch = try context.claimBranch(for: instance)

        let posNode = instance.nodes[0]
        let negNode = instance.nodes[1]
        let posIdx = context.nodeIndex(posNode)
        let negIdx = context.nodeIndex(negNode)
        let branchIdx = context.branchIndex(branch)

        // Pre-resolve CSR value indices for O(1) stamping
        let stampPB: Int? = if let i = posIdx, let b = branchIdx { context.stampIndex(row: i, col: b) } else { nil }
        let stampBP: Int? = if let b = branchIdx, let i = posIdx { context.stampIndex(row: b, col: i) } else { nil }
        let stampNB: Int? = if let j = negIdx, let b = branchIdx { context.stampIndex(row: j, col: b) } else { nil }
        let stampBN: Int? = if let b = branchIdx, let j = negIdx { context.stampIndex(row: b, col: j) } else { nil }

        return BoundVoltageSource(
            instance: instance,
            posNode: posNode,
            negNode: negNode,
            dcVoltage: dcVoltage,
            acMagnitude: acMagnitude,
            acPhaseDegrees: try IndependentSourceWaveformParser.real("acphase", instance: instance, defaultValue: 0),
            waveform: waveform,
            branch: branch,
            posIdx: posIdx,
            negIdx: negIdx,
            branchIdx: branchIdx,
            stampPB: stampPB,
            stampBP: stampBP,
            stampNB: stampNB,
            stampBN: stampBN
        )
    }

}
