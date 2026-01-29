import CoreSpiceIR

/// The result of a noise (.noise) analysis.
///
/// Contains the output noise spectral density at each frequency point,
/// individual device contributions, and the integrated output noise.
public struct NoiseResult: Sendable {

    /// Noise contribution from a single device noise source.
    public struct DeviceNoiseContribution: Sendable {
        /// The device instance name.
        public let deviceName: String
        /// The noise source name (e.g., "R1_thermal").
        public let noiseName: String
        /// The output-referred noise spectral density at each frequency (V²/Hz).
        public let spectralDensity: [Double]

        public init(deviceName: String, noiseName: String, spectralDensity: [Double]) {
            self.deviceName = deviceName
            self.noiseName = noiseName
            self.spectralDensity = spectralDensity
        }
    }

    /// The frequency points.
    public let frequencies: [Double]

    /// The total output noise spectral density at each frequency (V²/Hz).
    public let outputNoiseDensity: [Double]

    /// The input-referred noise spectral density at each frequency (V²/Hz).
    /// Computed as outputNoiseDensity / |gain|².
    public let inputReferredNoiseDensity: [Double]

    /// The integrated output noise over the frequency range (Vrms).
    public let integratedOutputNoise: Double

    /// Individual noise contributions from each device source.
    public let deviceContributions: [DeviceNoiseContribution]

    /// The variable map from the DC operating point.
    public let variableMap: [MNAVariable: Int]

    public init(
        frequencies: [Double],
        outputNoiseDensity: [Double],
        inputReferredNoiseDensity: [Double],
        integratedOutputNoise: Double,
        deviceContributions: [DeviceNoiseContribution],
        variableMap: [MNAVariable: Int]
    ) {
        self.frequencies = frequencies
        self.outputNoiseDensity = outputNoiseDensity
        self.inputReferredNoiseDensity = inputReferredNoiseDensity
        self.integratedOutputNoise = integratedOutputNoise
        self.deviceContributions = deviceContributions
        self.variableMap = variableMap
    }
}
