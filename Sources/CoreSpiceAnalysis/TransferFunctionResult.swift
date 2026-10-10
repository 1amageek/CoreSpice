import CoreSpiceIR

/// The result of a transfer function (.tf) analysis.
///
/// Contains the small-signal gain, input impedance, and output impedance
/// computed at the DC operating point.
public struct TransferFunctionResult: Sendable, AnalysisResultStorageRetaining {
    private let retainedStorage: (any Sendable)?

    /// The small-signal voltage gain (Vout / Vin).
    public let gain: Double

    /// The input impedance in ohms, seen at the input source terminals.
    public let inputImpedance: Double

    /// The output impedance in ohms, seen at the output node.
    public let outputImpedance: Double

    /// The DC operating point result used as the linearization point.
    public let dcOperatingPoint: DCResult

    /// Mapping from MNA variables to solution vector indices.
    public let variableMap: [MNAVariable: Int]

    public init(
        gain: Double,
        inputImpedance: Double,
        outputImpedance: Double,
        dcOperatingPoint: DCResult,
        variableMap: [MNAVariable: Int]
    ) throws {
        guard gain.isFinite else {
            throw AnalysisResultValidationError.nonFiniteValue(
                field: "gain",
                index: 0,
                value: gain
            )
        }
        guard !inputImpedance.isNaN else {
            throw AnalysisResultValidationError.nonFiniteValue(
                field: "inputImpedance",
                index: 0,
                value: inputImpedance
            )
        }
        guard !outputImpedance.isNaN else {
            throw AnalysisResultValidationError.nonFiniteValue(
                field: "outputImpedance",
                index: 0,
                value: outputImpedance
            )
        }
        guard variableMap == dcOperatingPoint.variableMap else {
            throw AnalysisResultValidationError.variableMapMismatch
        }
        self.gain = gain
        self.inputImpedance = inputImpedance
        self.outputImpedance = outputImpedance
        self.dcOperatingPoint = dcOperatingPoint
        self.variableMap = variableMap
        self.retainedStorage = nil
    }

    /// Returns the same numerical values while retaining their native invocation capacity.
    package func retainingStorage(_ owner: any Sendable) -> Self {
        Self(retaining: self, owner: owner)
    }

    private init(retaining result: Self, owner: any Sendable) {
        self.gain = result.gain
        self.inputImpedance = result.inputImpedance
        self.outputImpedance = result.outputImpedance
        self.dcOperatingPoint = result.dcOperatingPoint.retainingStorage(owner)
        self.variableMap = result.variableMap
        self.retainedStorage = owner
    }
}
