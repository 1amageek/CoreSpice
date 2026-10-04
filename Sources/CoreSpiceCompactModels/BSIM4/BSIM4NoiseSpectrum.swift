/// Original fourteen output PSD channels in V²/Hz. Padded slots remain zero.
public struct BSIM4NoiseSpectrum: Sendable {
    public let outputSpectralDensities: SIMD16<Double>
    public init(outputSpectralDensities: SIMD16<Double>) { self.outputSpectralDensities = outputSpectralDensities }
}
