import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceDiodeContracts

/// The result of a sensitivity (.sens) analysis.
///
/// Contains the sensitivity of a selected output variable to each device
/// parameter in the circuit.
public struct SensitivityResult: Sendable, AnalysisResultStorageRetaining {
    package let retainedStorage: (any Sendable)?

    /// Sensitivity of the output to a single device parameter.
    public struct ParameterSensitivity: Sendable {
        /// The device instance name (e.g., "R1").
        public let diodePreparation: DiodePreparationReceipt?
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
        public let perturbedValue: Double?
        public let effectiveIncrement: CompensatedValue?
        public let perturbedOutput: CompensatedValue?
        public let outputNode: Node?

        public init(
            deviceName: String,
            parameterName: String,
            nominalValue: Double,
            sensitivity: Double,
            normalizedSensitivity: Double?,
            perturbedValue: Double? = nil,
            effectiveIncrement: CompensatedValue? = nil,
            perturbedOutput: CompensatedValue? = nil,
            outputNode: Node? = nil,
            diodePreparation: DiodePreparationReceipt? = nil
        ) {
            self.diodePreparation = diodePreparation
            self.deviceName = deviceName
            self.parameterName = parameterName
            self.nominalValue = nominalValue
            self.sensitivity = sensitivity
            self.normalizedSensitivity = normalizedSensitivity
            self.perturbedValue = perturbedValue
            self.effectiveIncrement = effectiveIncrement
            self.perturbedOutput = perturbedOutput
            self.outputNode = outputNode
        }
    }

    /// The output variable name (e.g., "V(out)").
    public let outputVariable: String

    /// The baseline output value at the DC operating point.
    public let baselineValue: Double
    public let baselineOutput: CompensatedValue?
    public let outputNode: Node?

    /// Sensitivity of the output to each device parameter.
    public let sensitivities: [ParameterSensitivity]

    /// The baseline DC operating point result.
    public let dcOperatingPoint: DCResult

    public init(
        outputVariable: String,
        baselineValue: Double,
        sensitivities: [ParameterSensitivity],
        dcOperatingPoint: DCResult,
        baselineOutput: CompensatedValue? = nil,
        outputNode: Node? = nil
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
        guard (baselineOutput == nil) == (outputNode == nil) else {
            throw AnalysisError.invalidConfiguration("Sensitivity baseline observation is incomplete")
        }
        if let baselineOutput, let outputNode {
            guard baselineValue == baselineOutput.high + baselineOutput.low,
                  try dcOperatingPoint.checkedCompensatedVoltage(at: outputNode) == baselineOutput else {
                throw AnalysisError.invalidConfiguration("Sensitivity baseline observation does not match its actual DC result")
            }
        }
        for (index, entry) in sensitivities.enumerated() {
            let hasObservation = entry.perturbedValue != nil || entry.effectiveIncrement != nil
                || entry.perturbedOutput != nil || entry.outputNode != nil
            if hasObservation {
                guard let value = entry.perturbedValue, value.isFinite, let increment = entry.effectiveIncrement,
                      entry.perturbedOutput != nil, entry.outputNode != nil,
                      increment != .zero,
                      try CompensatedValue(high: value).subtracting(CompensatedValue(high: entry.nominalValue)) == increment else {
                    throw AnalysisError.invalidConfiguration("Sensitivity child observation is incomplete or has an inconsistent increment")
                }
            }
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
        self.baselineOutput = baselineOutput
        self.outputNode = outputNode
        self.sensitivities = sensitivities
        self.dcOperatingPoint = dcOperatingPoint
        self.retainedStorage = nil
    }

    /// Returns the same numerical values while retaining their native invocation capacity.
    package func retainingStorage(_ owner: any Sendable) -> Self {
        Self(retaining: self, owner: owner)
    }

    private init(retaining result: Self, owner: any Sendable) {
        self.outputVariable = result.outputVariable
        self.baselineValue = result.baselineValue
        self.baselineOutput = result.baselineOutput
        self.outputNode = result.outputNode
        self.sensitivities = result.sensitivities
        self.dcOperatingPoint = result.dcOperatingPoint.retainingStorage(owner)
        self.retainedStorage = owner
    }
}
