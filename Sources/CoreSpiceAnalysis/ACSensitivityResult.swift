import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceDiodeContracts

/// Frequency-dependent sensitivity of one output voltage to circuit parameters.
public struct ACSensitivityResult: Sendable, AnalysisResultStorageRetaining {
    package let retainedStorage: (any Sendable)?
    public struct ParameterSensitivity: Sendable {
        public let diodePreparation: DiodePreparationReceipt?
        public let deviceName: String
        public let parameterName: String
        public let nominalValue: Double
        public let sensitivities: [ComplexPair]
        public let normalizedSensitivities: [ComplexPair?]
        public let perturbedValue: Double?
        public let effectiveIncrement: CompensatedValue?
        public let perturbedValues: [ComplexPair]?
        public let outputPositiveNode: Node?
        public let outputReferenceNode: Node?

        public init(
            deviceName: String,
            parameterName: String,
            nominalValue: Double,
            sensitivities: [ComplexPair],
            normalizedSensitivities: [ComplexPair?],
            perturbedValue: Double? = nil,
            effectiveIncrement: CompensatedValue? = nil,
            perturbedValues: [ComplexPair]? = nil,
            outputPositiveNode: Node? = nil,
            outputReferenceNode: Node? = nil,
            diodePreparation: DiodePreparationReceipt? = nil
        ) {
            self.diodePreparation = diodePreparation
            self.deviceName = deviceName
            self.parameterName = parameterName
            self.nominalValue = nominalValue
            self.sensitivities = sensitivities
            self.normalizedSensitivities = normalizedSensitivities
            self.perturbedValue = perturbedValue
            self.effectiveIncrement = effectiveIncrement
            self.perturbedValues = perturbedValues
            self.outputPositiveNode = outputPositiveNode
            self.outputReferenceNode = outputReferenceNode
        }
    }

    public let outputVariable: String
    public let frequencies: [Double]
    public let baselineValues: [ComplexPair]
    public let operatingPoint: DCResult?
    public let sensitivities: [ParameterSensitivity]
    public let outputPositiveNode: Node?
    public let outputReferenceNode: Node?

    public init(
        outputVariable: String,
        frequencies: [Double],
        baselineValues: [ComplexPair],
        sensitivities: [ParameterSensitivity],
        outputPositiveNode: Node? = nil,
        outputReferenceNode: Node? = nil,
        operatingPoint: DCResult? = nil
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
            let hasObservation = entry.perturbedValue != nil || entry.effectiveIncrement != nil
                || entry.perturbedValues != nil || entry.outputPositiveNode != nil || entry.outputReferenceNode != nil
            if hasObservation {
                guard let value = entry.perturbedValue, value.isFinite, let increment = entry.effectiveIncrement,
                      let values = entry.perturbedValues, entry.outputPositiveNode != nil,
                      values.count == frequencies.count, values.allSatisfy({ $0.real.isFinite && $0.imag.isFinite }),
                      increment != .zero,
                      try CompensatedValue(high: value).subtracting(CompensatedValue(high: entry.nominalValue)) == increment else {
                    throw AnalysisError.invalidConfiguration("AC sensitivity child observation is incomplete or has an inconsistent increment")
                }
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
        self.operatingPoint = operatingPoint
        self.sensitivities = sensitivities
        self.outputPositiveNode = outputPositiveNode
        self.outputReferenceNode = outputReferenceNode
        self.retainedStorage = nil
    }

    /// Returns the same numerical values while retaining their native invocation capacity.
    package func retainingStorage(_ owner: any Sendable) -> Self {
        Self(retaining: self, owner: owner)
    }

    private init(retaining result: Self, owner: any Sendable) {
        self.outputVariable = result.outputVariable
        self.frequencies = result.frequencies
        self.baselineValues = result.baselineValues
        self.operatingPoint = result.operatingPoint?.retainingStorage(owner)
        self.sensitivities = result.sensitivities
        self.outputPositiveNode = result.outputPositiveNode
        self.outputReferenceNode = result.outputReferenceNode
        self.retainedStorage = owner
    }
}
