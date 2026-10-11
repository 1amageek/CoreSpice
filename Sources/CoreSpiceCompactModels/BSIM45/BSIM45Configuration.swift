/// Separate numeric-ID inputs; backing storage is borrowed only during preparation.
public struct BSIM45Configuration: Sendable {
    public enum Polarity: Int32, Sendable { case nmos = 1, pmos = -1 }
    public let polarity: Polarity
    public let version: String
    public let temperature: Double
    public let nominalTemperature: Double
    public let noiseRequested: Bool
    public let maximumStressIterations: UInt32
    public let modelParameters: [BSIM45Parameter]
    public let instanceParameters: [BSIM45Parameter]
    public let initialConditions: SIMD3<Double>?
    public init(polarity: Polarity, version: String = "4.5.0", temperature: Double = 300.15,
                nominalTemperature: Double = 300.15, noiseRequested: Bool, maximumStressIterations: UInt32,
                modelParameters: [BSIM45Parameter] = [], instanceParameters: [BSIM45Parameter] = [],
                initialConditions: SIMD3<Double>? = nil) {
        self.polarity = polarity; self.version = version; self.temperature = temperature
        self.nominalTemperature = nominalTemperature; self.noiseRequested = noiseRequested
        self.maximumStressIterations = maximumStressIterations; self.modelParameters = modelParameters
        self.instanceParameters = instanceParameters; self.initialConditions = initialConditions
    }
}
