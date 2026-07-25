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
    ) throws {
        let count = frequencies.count
        guard count > 0 else {
            throw AnalysisResultValidationError.countMismatch(
                field: "frequencies",
                expected: 1,
                actual: 0
            )
        }
        guard outputNoiseDensity.count == count else {
            throw AnalysisResultValidationError.countMismatch(
                field: "outputNoiseDensity",
                expected: count,
                actual: outputNoiseDensity.count
            )
        }
        guard inputReferredNoiseDensity.count == count else {
            throw AnalysisResultValidationError.countMismatch(
                field: "inputReferredNoiseDensity",
                expected: count,
                actual: inputReferredNoiseDensity.count
            )
        }
        for contribution in deviceContributions {
            guard contribution.spectralDensity.count == count else {
                throw AnalysisResultValidationError.countMismatch(
                    field: "deviceContributions.\(contribution.noiseName)",
                    expected: count,
                    actual: contribution.spectralDensity.count
                )
            }
        }
        try Self.validateNonNegativeFinite(frequencies, field: "frequencies")
        for index in frequencies.indices.dropFirst()
        where frequencies[index] <= frequencies[index - 1] {
            throw AnalysisResultValidationError.nonIncreasingValue(
                field: "frequencies",
                index: index,
                previous: frequencies[index - 1],
                value: frequencies[index]
            )
        }
        try Self.validateNonNegativeFinite(outputNoiseDensity, field: "outputNoiseDensity")
        try Self.validateNonNegativeFinite(
            inputReferredNoiseDensity,
            field: "inputReferredNoiseDensity"
        )
        for contribution in deviceContributions {
            try Self.validateNonNegativeFinite(
                contribution.spectralDensity,
                field: "deviceContributions.\(contribution.noiseName)"
            )
        }
        guard integratedOutputNoise.isFinite else {
            throw AnalysisResultValidationError.nonFiniteValue(
                field: "integratedOutputNoise",
                index: 0,
                value: integratedOutputNoise
            )
        }
        guard integratedOutputNoise >= 0 else {
            throw AnalysisResultValidationError.negativeValue(
                field: "integratedOutputNoise",
                index: 0,
                value: integratedOutputNoise
            )
        }
        self.frequencies = frequencies
        self.outputNoiseDensity = outputNoiseDensity
        self.inputReferredNoiseDensity = inputReferredNoiseDensity
        self.integratedOutputNoise = integratedOutputNoise
        self.deviceContributions = deviceContributions
        self.variableMap = variableMap
    }

    private static func validateNonNegativeFinite(
        _ values: [Double],
        field: String
    ) throws {
        for (index, value) in values.enumerated() {
            guard value.isFinite else {
                throw AnalysisResultValidationError.nonFiniteValue(
                    field: field,
                    index: index,
                    value: value
                )
            }
            guard value >= 0 else {
                throw AnalysisResultValidationError.negativeValue(
                    field: field,
                    index: index,
                    value: value
                )
            }
        }
    }
}
