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
        public let normalizedSensitivity: Double

        public init(
            deviceName: String,
            parameterName: String,
            nominalValue: Double,
            sensitivity: Double,
            normalizedSensitivity: Double
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
    ) {
        self.outputVariable = outputVariable
        self.baselineValue = baselineValue
        self.sensitivities = sensitivities
        self.dcOperatingPoint = dcOperatingPoint
    }
}
