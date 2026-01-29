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

        let waveform = try parseWaveform(from: instance)
        let dcVoltage = waveform.dcValue

        let branch = context.allocateBranch()

        return BoundVoltageSource(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            dcVoltage: dcVoltage,
            waveform: waveform,
            branch: branch
        )
    }

    // MARK: - Waveform Parsing

    private func parseWaveform(from instance: Instance) throws -> Waveform {
        let params = instance.parameters

        // Check for pulse parameters (v1 and v2 are required)
        if let v1Param = params["v1"], let v2Param = params["v2"] {
            guard case .real(let v1) = v1Param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "v1", expected: "real"
                )
            }
            guard case .real(let v2) = v2Param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "v2", expected: "real"
                )
            }
            let td = extractReal(params["td"]) ?? 0.0
            let tr = extractReal(params["tr"]) ?? 0.0
            let tf = extractReal(params["tf"]) ?? 0.0
            let pw = extractReal(params["pw"]) ?? 0.0
            let per = extractReal(params["per"]) ?? 0.0

            // Validate period (must be positive for periodic waveform)
            guard per > 0 else {
                throw DeviceBindingError.invalidParameterValue(
                    device: instance.name, parameter: "per",
                    message: "Period must be positive for pulse waveform"
                )
            }

            return .pulse(v1: v1, v2: v2, delay: td, rise: tr, fall: tf, width: pw, period: per)
        }

        // Check for sine parameters (vo, va, freq are required)
        if let voParam = params["vo"], let vaParam = params["va"], let freqParam = params["freq"] {
            guard case .real(let vo) = voParam else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "vo", expected: "real"
                )
            }
            guard case .real(let va) = vaParam else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "va", expected: "real"
                )
            }
            guard case .real(let freq) = freqParam else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "freq", expected: "real"
                )
            }
            let td = extractReal(params["td"]) ?? 0.0
            let phase = extractReal(params["phase"]) ?? 0.0

            return .sine(offset: vo, amplitude: va, frequency: freq, delay: td, phase: phase)
        }

        // Default: DC waveform
        let v = extractReal(params["v"]) ?? 0.0
        return .dc(v)
    }

    private func extractReal(_ value: ParameterValue?) -> Double? {
        guard let value else { return nil }
        if case .real(let v) = value {
            return v
        }
        return nil
    }
}
