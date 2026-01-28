/// Configuration for a wavelength-sweep batch simulation.
///
/// Defines which wavelengths to sweep, how many repetitions to
/// perform per wavelength, and which input port receives the signal.
public struct PhotonicSweepBatch: Sendable {

    /// Wavelengths to sweep in meters.
    public let wavelengths: [Double]

    /// Number of repetitions per wavelength (for noise averaging).
    public let repetitions: Int

    /// Index of the input port that receives the signal (0--511).
    public let inputPortIndex: Int

    /// Amplitude of the input signal (linear).
    public let inputAmplitude: Double

    public init(
        wavelengths: [Double],
        repetitions: Int = 1,
        inputPortIndex: Int = 0,
        inputAmplitude: Double = 1.0
    ) {
        self.wavelengths = wavelengths
        self.repetitions = repetitions
        self.inputPortIndex = inputPortIndex
        self.inputAmplitude = inputAmplitude
    }

    /// Total number of state vectors in one GPU dispatch.
    public var totalBatchSize: Int { wavelengths.count * repetitions }
}
