import CoreSpiceIR
import CoreSpiceDevices

/// The result of a noise (.noise) analysis.
///
/// Contains the output noise spectral density at each frequency point,
/// individual device contributions, and the integrated output noise.
public struct NoiseResult: Sendable, AnalysisResultStorageRetaining {
    package let retainedStorage: (any Sendable)?

    /// Noise contribution from a single device noise source.
    public struct DeviceNoiseContribution: Sendable {
        /// The device instance name.
        public let deviceName: String
        /// The noise source name (e.g., "R1_thermal").
        public let noiseName: String
        /// The output-referred noise spectral density at each frequency (V²/Hz).
        public let spectralDensity: [Double]
        /// Present for a canonical residual source; source PSD is in residual-unit squared per Hz.
        public let residualSource: ResidualNoiseSource?
        public let sourceSpectralDensity: [Double]?

        public init(deviceName: String, noiseName: String, spectralDensity: [Double],
                    residualSource: ResidualNoiseSource? = nil, sourceSpectralDensity: [Double]? = nil) {
            self.deviceName = deviceName
            self.noiseName = noiseName
            self.spectralDensity = spectralDensity
            self.residualSource = residualSource; self.sourceSpectralDensity = sourceSpectralDensity
        }
    }

    /// The frequency points.
    public let frequencies: [Double]

    /// The total output noise spectral density at each frequency (V²/Hz).
    public let outputNoiseDensity: [Double]

    /// The input-referred noise spectral density, V²/Hz or A²/Hz according to inputQuantity.
    /// Computed as outputNoiseDensity / |gain|².
    public let inputReferredNoiseDensity: [Double]

    /// The integrated output noise over the frequency range (Vrms).
    public let integratedOutputNoise: Double

    /// Individual noise contributions from each device source.
    public let deviceContributions: [DeviceNoiseContribution]

    /// The variable map from the DC operating point.
    public let variableMap: [MNAVariable: Int]
    public let inputQuantity: NoiseInputQuantity
    public let operatingPoint: DCResult?

    public init(
        frequencies: [Double],
        outputNoiseDensity: [Double],
        inputReferredNoiseDensity: [Double],
        integratedOutputNoise: Double,
        deviceContributions: [DeviceNoiseContribution],
        variableMap: [MNAVariable: Int],
        inputQuantity: NoiseInputQuantity = .voltage,
        operatingPoint: DCResult? = nil
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
        for contribution in deviceContributions {
            guard (contribution.residualSource == nil) == (contribution.sourceSpectralDensity == nil) else {
                throw AnalysisError.invalidConfiguration("Noise residual metadata and source PSD must be supplied together")
            }
            if let density = contribution.sourceSpectralDensity {
                guard density.count == count else {
                    throw AnalysisResultValidationError.countMismatch(field: "sourceSpectralDensity", expected: count, actual: density.count)
                }
                try Self.validateNonNegativeFinite(density, field: "sourceSpectralDensity")
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
        if let operatingPoint, operatingPoint.variableMap != variableMap {
            throw AnalysisResultValidationError.variableMapMismatch
        }
        self.frequencies = frequencies
        self.outputNoiseDensity = outputNoiseDensity
        self.inputReferredNoiseDensity = inputReferredNoiseDensity
        self.integratedOutputNoise = integratedOutputNoise
        self.deviceContributions = deviceContributions
        self.variableMap = variableMap
        self.inputQuantity = inputQuantity; self.operatingPoint = operatingPoint
        self.retainedStorage = nil
    }

    /// Returns the same numerical values while retaining their native invocation capacity.
    package func retainingStorage(_ owner: any Sendable) -> Self {
        Self(retaining: self, owner: owner)
    }

    private init(retaining result: Self, owner: any Sendable) {
        self.frequencies = result.frequencies
        self.outputNoiseDensity = result.outputNoiseDensity
        self.inputReferredNoiseDensity = result.inputReferredNoiseDensity
        self.integratedOutputNoise = result.integratedOutputNoise
        self.deviceContributions = result.deviceContributions
        self.variableMap = result.variableMap
        self.inputQuantity = result.inputQuantity; self.operatingPoint = result.operatingPoint?.retainingStorage(owner)
        self.retainedStorage = owner
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
