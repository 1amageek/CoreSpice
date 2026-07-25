import CoreSpiceIR

/// The result of a sensitivity (.sens) analysis.
///
/// Contains the sensitivity of a selected output variable to each device
/// parameter in the circuit.
public struct SensitivityResult: Sendable {

    /// Sensitivity of the output to a single device parameter.
    public struct ParameterSensitivity: Sendable {
        /// The device instance name (e.g., "R1").
        public let deviceName: String
        /// The parameter name (e.g., "r").
        public let parameterName: String
        /// The nominal parameter value.
        public let nominalValue: Double
        /// Absolute sensitivity: dOutput/dParam.
        public let sensitivity: Double
        /// Normalized sensitivity: (dOutput/Output) / (dParam/Param).
        /// Normalized sensitivity, or `nil` when the baseline output is zero.
        public let normalizedSensitivity: Double?

        public init(
            deviceName: String,
            parameterName: String,
            nominalValue: Double,
            sensitivity: Double,
            normalizedSensitivity: Double?
        ) {
            self.deviceName = deviceName
            self.parameterName = parameterName
            self.nominalValue = nominalValue
            self.sensitivity = sensitivity
            self.normalizedSensitivity = normalizedSensitivity
        }
    }

    /// The output variable name (e.g., "V(out)").
    public let outputVariable: String

    /// The baseline output value at the DC operating point.
    public let baselineValue: Double

    /// Sensitivity of the output to each device parameter.
    public let sensitivities: [ParameterSensitivity]

    /// The baseline DC operating point result.
    public let dcOperatingPoint: DCResult

    public init(
        outputVariable: String,
        baselineValue: Double,
        sensitivities: [ParameterSensitivity],
        dcOperatingPoint: DCResult
    ) throws {
        guard !outputVariable.isEmpty else {
            throw AnalysisResultValidationError.emptyOutputVariable
        }
        guard baselineValue.isFinite else {
            throw AnalysisResultValidationError.nonFiniteValue(
                field: "baselineValue",
                index: 0,
                value: baselineValue
            )
        }
        for (index, entry) in sensitivities.enumerated() {
            guard entry.nominalValue.isFinite else {
                throw AnalysisResultValidationError.nonFiniteValue(
                    field: "sensitivities.nominalValue",
                    index: index,
                    value: entry.nominalValue
                )
            }
            guard entry.sensitivity.isFinite else {
                throw AnalysisResultValidationError.nonFiniteValue(
                    field: "sensitivities.sensitivity",
                    index: index,
                    value: entry.sensitivity
                )
            }
            if let normalized = entry.normalizedSensitivity,
               !normalized.isFinite {
                throw AnalysisResultValidationError.nonFiniteValue(
                    field: "sensitivities.normalizedSensitivity",
                    index: index,
                    value: normalized
                )
            }
        }
        self.outputVariable = outputVariable
        self.baselineValue = baselineValue
        self.sensitivities = sensitivities
        self.dcOperatingPoint = dcOperatingPoint
    }
}
