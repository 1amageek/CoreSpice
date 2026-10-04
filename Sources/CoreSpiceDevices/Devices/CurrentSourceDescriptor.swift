import CoreSpiceIR

/// Descriptor for an independent current source.
///
/// Supports DC current and time-varying waveforms for transient analysis.
/// Waveform types:
/// - DC: `i` parameter only
/// - Pulse: `i1`, `i2`, `td`, `tr`, `tf`, `pw`, `per` parameters
/// - Sine: `io`, `ia`, `freq`, `td`, `phase` parameters
public struct CurrentSourceDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "isource"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "pwl", defaultValue: nil, description: "Alternating finite time/value pairs"),
        ParameterDescriptor(name: "ac", defaultValue: .real(0), description: "AC small-signal magnitude"),
        // DC
        ParameterDescriptor(name: "i", defaultValue: .real(0.0), description: "DC current in amperes"),
        // Pulse waveform
        ParameterDescriptor(name: "i1", defaultValue: nil, description: "Initial pulse value"),
        ParameterDescriptor(name: "i2", defaultValue: nil, description: "Pulsed value"),
        ParameterDescriptor(name: "td", defaultValue: .real(0.0), description: "Delay time"),
        ParameterDescriptor(name: "tr", defaultValue: .real(0.0), description: "Rise time"),
        ParameterDescriptor(name: "tf", defaultValue: .real(0.0), description: "Fall time"),
        ParameterDescriptor(name: "pw", defaultValue: .real(0.0), description: "Pulse width"),
        ParameterDescriptor(name: "per", defaultValue: .real(0.0), description: "Period"),
        // Sine waveform
        ParameterDescriptor(name: "io", defaultValue: nil, description: "Offset current"),
        ParameterDescriptor(name: "ia", defaultValue: nil, description: "Amplitude"),
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

        let waveform = try IndependentSourceWaveformParser.parse(instance, current: true)
        let dcCurrent = waveform.dcValue
        let acMagnitude = try IndependentSourceWaveformParser.real("ac", instance: instance, defaultValue: 0)

        return BoundCurrentSource(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            dcCurrent: dcCurrent,
            acMagnitude: acMagnitude,
            waveform: waveform,
            posIdx: context.nodeIndex(instance.nodes[0]),
            negIdx: context.nodeIndex(instance.nodes[1])
        )
    }

}
