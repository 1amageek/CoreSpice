/// Separate original model/instance parameters, with exact kernel version identity.
public struct BSIM3Configuration: Sendable {
    public enum Polarity: Int32, Sendable { case nmos = 1, pmos = -1 }
    public var polarity: Polarity
    public var version: String
    public var temperature: Double
    public var modelParameters: [String: Double]
    public var instanceParameters: [String: Double]
    /// Original IC vector order: drain-source, gate-source, bulk-source volts.
    public var initialConditions: SIMD3<Double>?

    public init(polarity: Polarity = .nmos, version: String = "3.3.0", temperature: Double = 300.15,
                modelParameters: [String: Double] = [:], instanceParameters: [String: Double] = [:],
                initialConditions: SIMD3<Double>? = nil) {
        self.polarity = polarity
        self.version = version
        self.temperature = temperature
        self.modelParameters = modelParameters
        self.instanceParameters = instanceParameters
        self.initialConditions = initialConditions
    }
}
