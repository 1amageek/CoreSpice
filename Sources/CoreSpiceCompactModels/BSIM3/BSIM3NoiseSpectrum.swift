/// Original uncorrelated source current PSDs, in A²/Hz. Values own their storage.
public struct BSIM3NoiseSpectrum: Sendable {
    /// Drain series, source series, channel thermal, and flicker, in that order.
    public let currentSpectralDensities: SIMD4<Double>
    public init(currentSpectralDensities: SIMD4<Double>) {
        self.currentSpectralDensities = currentSpectralDensities
    }
}
