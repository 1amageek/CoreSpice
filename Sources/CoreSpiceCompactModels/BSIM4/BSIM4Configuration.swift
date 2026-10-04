/// One exact original release, with model and instance scopes kept separate.
public struct BSIM4Configuration: Sendable {
    public enum Polarity: Int32, Sendable { case nmos = 1, pmos = -1 }
    public let polarity: Polarity
    public let version: String
    public let temperature: Double
    public let noiseRequested: Bool
    public let maximumStressIterations: UInt32
    public let modelParameters: [String: Double]
    public let instanceParameters: [String: Double]
    public let initialConditions: SIMD3<Double>?
    public init(polarity: Polarity, version: String = "4.8.3", temperature: Double = 300.15,
                noiseRequested: Bool, maximumStressIterations: UInt32, modelParameters: [String: Double] = [:],
                instanceParameters: [String: Double] = [:], initialConditions: SIMD3<Double>? = nil) {
        self.polarity = polarity; self.version = version; self.temperature = temperature
        self.maximumStressIterations = maximumStressIterations
        self.noiseRequested = noiseRequested; self.modelParameters = modelParameters
        self.instanceParameters = instanceParameters; self.initialConditions = initialConditions
    }
}
