/// Process corner type for PVT analysis.
///
/// Process corners represent manufacturing variations in semiconductor devices.
public enum ProcessCorner: String, Sendable, Hashable, Codable {

    /// Typical-typical (nominal) corner.
    case tt = "TT"

    /// Fast-fast corner (best-case speed).
    case ff = "FF"

    /// Slow-slow corner (worst-case speed).
    case ss = "SS"

    /// Fast-slow (fast NMOS, slow PMOS).
    case fs = "FS"

    /// Slow-fast (slow NMOS, fast PMOS).
    case sf = "SF"

    /// Custom corner.
    case custom
}

/// A PVT (Process-Voltage-Temperature) corner specification.
///
/// PVT corners are used for characterizing circuit performance
/// across manufacturing variations and operating conditions.
public struct PVTCorner: Sendable, Hashable {

    /// The process corner.
    public let process: ProcessCorner

    /// The supply voltage in volts.
    public let voltage: Double

    /// The temperature in Celsius.
    public let temperature: Double

    /// An optional name for this corner.
    public let name: String?

    /// Additional parameters for this corner.
    public let parameters: [String: ParsedParameterValue]

    public init(
        process: ProcessCorner,
        voltage: Double,
        temperature: Double,
        name: String? = nil,
        parameters: [String: ParsedParameterValue] = [:]
    ) {
        self.process = process
        self.voltage = voltage
        self.temperature = temperature
        self.name = name
        self.parameters = parameters
    }

    /// A typical corner at nominal conditions.
    public static let typical = PVTCorner(
        process: .tt,
        voltage: 1.0,
        temperature: 25.0,
        name: "typical"
    )
}

extension PVTCorner: CustomStringConvertible {
    public var description: String {
        let n = name ?? "\(process.rawValue)_\(voltage)V_\(temperature)C"
        return n
    }
}

/// Monte Carlo variation specification for a parameter.
public struct MCVariation: Sendable, Hashable {

    /// The parameter to vary.
    public let parameter: String

    /// The distribution type.
    public let distribution: DistributionType

    /// The standard deviation or range.
    public let sigma: Double

    /// Whether this is a lot-to-lot or device-to-device variation.
    public let variationType: VariationType

    public enum VariationType: String, Sendable, Hashable, Codable {
        case lot
        case device
    }

    public init(
        parameter: String,
        distribution: DistributionType,
        sigma: Double,
        variationType: VariationType = .device
    ) {
        self.parameter = parameter
        self.distribution = distribution
        self.sigma = sigma
        self.variationType = variationType
    }
}
