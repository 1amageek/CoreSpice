import CoreSpiceIR

/// The result of a transfer function (.tf) analysis.
///
/// Contains the small-signal gain, input impedance, and output impedance
/// computed at the DC operating point.
public struct TransferFunctionResult: Sendable, AnalysisResultStorageRetaining {
    package let retainedStorage: (any Sendable)?

    /// The small-signal voltage gain (Vout / Vin).
    public let gain: Double

    /// The input impedance in ohms, seen at the input source terminals.
    public var inputImpedance: Double { inputPortImpedance.ohms }
    public let inputPortImpedance: PortImpedance

    /// The output impedance in ohms, seen at the output node.
    public var outputImpedance: Double { outputPortImpedance.ohms }
    public let outputPortImpedance: PortImpedance

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
        try self.init(gain: gain, inputPortImpedance: PortImpedance(ohms: inputImpedance),
            outputPortImpedance: PortImpedance(ohms: outputImpedance),
            dcOperatingPoint: dcOperatingPoint, variableMap: variableMap)
    }

    public init(
        gain: Double,
        inputPortImpedance: PortImpedance,
        outputPortImpedance: PortImpedance,
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
        try inputPortImpedance.validate(field: "inputImpedance")
        try outputPortImpedance.validate(field: "outputImpedance")
        guard variableMap == dcOperatingPoint.variableMap else {
            throw AnalysisResultValidationError.variableMapMismatch
        }
        self.gain = gain
        self.inputPortImpedance = inputPortImpedance
        self.outputPortImpedance = outputPortImpedance
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
        self.inputPortImpedance = result.inputPortImpedance
        self.outputPortImpedance = result.outputPortImpedance
        self.dcOperatingPoint = result.dcOperatingPoint.retainingStorage(owner)
        self.variableMap = result.variableMap
        self.retainedStorage = owner
    }
}
