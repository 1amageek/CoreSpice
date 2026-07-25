import CoreSpiceCompile

/// Frequency-dependent sensitivity of one output voltage to circuit parameters.
public struct ACSensitivityResult: Sendable {
    public struct ParameterSensitivity: Sendable {
        public let deviceName: String
        public let parameterName: String
        public let nominalValue: Double
        public let sensitivities: [ComplexPair]
        public let normalizedSensitivities: [ComplexPair?]

        public init(
            deviceName: String,
            parameterName: String,
            nominalValue: Double,
            sensitivities: [ComplexPair],
            normalizedSensitivities: [ComplexPair?]
        ) {
            self.deviceName = deviceName
            self.parameterName = parameterName
            self.nominalValue = nominalValue
            self.sensitivities = sensitivities
            self.normalizedSensitivities = normalizedSensitivities
        }
    }

    public let outputVariable: String
    public let frequencies: [Double]
    public let baselineValues: [ComplexPair]
    public let sensitivities: [ParameterSensitivity]

    public init(
        outputVariable: String,
        frequencies: [Double],
        baselineValues: [ComplexPair],
        sensitivities: [ParameterSensitivity]
    ) throws {
        guard !outputVariable.isEmpty else {
            throw AnalysisResultValidationError.emptyOutputVariable
        }
        guard frequencies.count == baselineValues.count else {
            throw AnalysisError.invalidConfiguration(
                "AC sensitivity baseline count must match the frequency count"
            )
        }
        for (index, frequency) in frequencies.enumerated() {
            guard frequency.isFinite else {
                throw AnalysisResultValidationError.nonFiniteValue(
                    field: "frequencies",
                    index: index,
                    value: frequency
                )
            }
            guard frequency > 0 else {
                throw AnalysisResultValidationError.negativeValue(
                    field: "frequencies",
                    index: index,
                    value: frequency
                )
            }
            if index > 0, frequency <= frequencies[index - 1] {
                throw AnalysisResultValidationError.nonIncreasingValue(
                    field: "frequencies",
                    index: index,
                    previous: frequencies[index - 1],
                    value: frequency
                )
            }
        }
        for (index, value) in baselineValues.enumerated() {
            guard value.real.isFinite, value.imag.isFinite else {
                throw AnalysisResultValidationError.nonFiniteComplex(
                    field: "baselineValues",
                    index: index
                )
            }
        }
        for entry in sensitivities {
            guard entry.sensitivities.count == frequencies.count,
                  entry.normalizedSensitivities.count == frequencies.count else {
                throw AnalysisError.invalidConfiguration(
                    "AC sensitivity data count for \(entry.deviceName).\(entry.parameterName) must match the frequency count"
                )
            }
            guard entry.nominalValue.isFinite else {
                throw AnalysisResultValidationError.nonFiniteValue(
                    field: "\(entry.deviceName).\(entry.parameterName).nominalValue",
                    index: 0,
                    value: entry.nominalValue
                )
            }
            for (index, value) in entry.sensitivities.enumerated() {
                guard value.real.isFinite, value.imag.isFinite else {
                    throw AnalysisResultValidationError.nonFiniteComplex(
                        field: "\(entry.deviceName).\(entry.parameterName).sensitivities",
                        index: index
                    )
                }
            }
            for (index, value) in entry.normalizedSensitivities.enumerated() {
                guard let value else { continue }
                guard value.real.isFinite, value.imag.isFinite else {
                    throw AnalysisResultValidationError.nonFiniteComplex(
                        field: "\(entry.deviceName).\(entry.parameterName).normalizedSensitivities",
                        index: index
                    )
                }
            }
        }
        self.outputVariable = outputVariable
        self.frequencies = frequencies
        self.baselineValues = baselineValues
        self.sensitivities = sensitivities
    }
}
