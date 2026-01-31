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

        let waveform = try parseWaveform(from: instance)
        let dcCurrent = waveform.dcValue
        let acMagnitude = extractReal(instance.parameters["ac"]) ?? 0.0

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

    // MARK: - Waveform Parsing

    private func parseWaveform(from instance: Instance) throws -> Waveform {
        let params = instance.parameters

        // Check for pulse parameters (i1 and i2 are required)
        if let i1Param = params["i1"], let i2Param = params["i2"] {
            guard case .real(let i1) = i1Param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "i1", expected: "real"
                )
            }
            guard case .real(let i2) = i2Param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "i2", expected: "real"
                )
            }
            let td = extractReal(params["td"]) ?? 0.0
            let tr = extractReal(params["tr"]) ?? 0.0
            let tf = extractReal(params["tf"]) ?? 0.0
            let pw = extractReal(params["pw"]) ?? 0.0
            let per = extractReal(params["per"]) ?? 0.0

            // Validate period
            guard per > 0 else {
                throw DeviceBindingError.invalidParameterValue(
                    device: instance.name, parameter: "per",
                    message: "Period must be positive for pulse waveform"
                )
            }

            return .pulse(v1: i1, v2: i2, delay: td, rise: tr, fall: tf, width: pw, period: per)
        }

        // Check for sine parameters (io, ia, freq are required)
        if let ioParam = params["io"], let iaParam = params["ia"], let freqParam = params["freq"] {
            guard case .real(let io) = ioParam else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "io", expected: "real"
                )
            }
            guard case .real(let ia) = iaParam else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "ia", expected: "real"
                )
            }
            guard case .real(let freq) = freqParam else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "freq", expected: "real"
                )
            }
            let td = extractReal(params["td"]) ?? 0.0
            let phase = extractReal(params["phase"]) ?? 0.0

            return .sine(offset: io, amplitude: ia, frequency: freq, delay: td, phase: phase)
        }

        // Default: DC waveform
        let i = extractReal(params["i"]) ?? 0.0
        return .dc(i)
    }

    private func extractReal(_ value: ParameterValue?) -> Double? {
        guard let value else { return nil }
        if case .real(let v) = value {
            return v
        }
        return nil
    }
}
