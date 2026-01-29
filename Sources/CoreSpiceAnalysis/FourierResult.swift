/// The result of a Fourier (.four) analysis.
///
/// Contains harmonic components and total harmonic distortion (THD)
/// computed from the final period of a transient simulation.
public struct FourierResult: Sendable {

    /// A single harmonic component of the Fourier decomposition.
    public struct HarmonicComponent: Sendable {
        /// The harmonic number (1 = fundamental, 2 = 2nd harmonic, etc.).
        public let harmonic: Int
        /// The frequency of this harmonic in Hz.
        public let frequency: Double
        /// The magnitude of this harmonic.
        public let magnitude: Double
        /// The phase of this harmonic in degrees.
        public let phase: Double
        /// The magnitude normalized to the fundamental.
        public let normalizedMagnitude: Double

        public init(
            harmonic: Int,
            frequency: Double,
            magnitude: Double,
            phase: Double,
            normalizedMagnitude: Double
        ) {
            self.harmonic = harmonic
            self.frequency = frequency
            self.magnitude = magnitude
            self.phase = phase
            self.normalizedMagnitude = normalizedMagnitude
        }
    }

    /// The fundamental frequency in Hz.
    public let fundamentalFrequency: Double

    /// Harmonic components for each analyzed variable.
    ///
    /// Key: variable name (e.g., "V(out)"), Value: array of harmonic components.
    public let harmonics: [String: [HarmonicComponent]]

    /// Total harmonic distortion percentage for each analyzed variable.
    ///
    /// THD = sqrt(sum of |Xk|^2 for k >= 2) / |X1| * 100%
    public let thd: [String: Double]

    /// The underlying transient result.
    public let transientResult: TransientResult

    public init(
        fundamentalFrequency: Double,
        harmonics: [String: [HarmonicComponent]],
        thd: [String: Double],
        transientResult: TransientResult
    ) {
        self.fundamentalFrequency = fundamentalFrequency
        self.harmonics = harmonics
        self.thd = thd
        self.transientResult = transientResult
    }
}
