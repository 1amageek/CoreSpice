/// A stable device-owned channel already referred to the selected output (V²/Hz).
public struct OutputNoiseSource: Sendable {
    public let name: String
    public let outputSpectralDensity: Double
    public init(name: String, outputSpectralDensity: Double) {
        self.name = name; self.outputSpectralDensity = outputSpectralDensity
    }
}
