/// Thirteen original sources followed by their sum; slots 14/15 are zero padding.
public struct BSIM45NoiseSpectrum: Sendable {
    public let frequency: Double
    public let outputSpectralDensities: SIMD16<Double>
}
