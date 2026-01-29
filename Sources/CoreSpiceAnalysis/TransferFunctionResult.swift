import CoreSpiceIR

/// The result of a transfer function (.tf) analysis.
///
/// Contains the small-signal gain, input impedance, and output impedance
/// computed at the DC operating point.
public struct TransferFunctionResult: Sendable {

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
    ) {
        self.gain = gain
        self.inputImpedance = inputImpedance
        self.outputImpedance = outputImpedance
        self.dcOperatingPoint = dcOperatingPoint
        self.variableMap = variableMap
    }
}
