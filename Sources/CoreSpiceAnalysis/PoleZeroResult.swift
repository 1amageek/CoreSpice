import CoreSpiceCompile
import CoreSpiceIR

/// The result of a pole-zero (.pz) analysis.
///
/// Contains the poles and zeros of the circuit transfer function,
/// along with the DC gain. Poles are values of the complex frequency
/// variable `s` where the denominator of the transfer function is zero.
/// Zeros are values where the numerator is zero.
public struct PoleZeroResult: Sendable {

    /// The poles of the circuit transfer function (complex frequencies in rad/s).
    public let poles: [ComplexPair]

    /// The zeros of the transfer function (complex frequencies in rad/s).
    public let zeros: [ComplexPair]

    /// The DC gain of the transfer function (dimensionless).
    public let dcGain: Double

    /// The variable map from the analysis.
    public let variableMap: [MNAVariable: Int]

    public init(
        poles: [ComplexPair],
        zeros: [ComplexPair],
        dcGain: Double,
        variableMap: [MNAVariable: Int]
    ) {
        self.poles = poles
        self.zeros = zeros
        self.dcGain = dcGain
        self.variableMap = variableMap
    }
}
