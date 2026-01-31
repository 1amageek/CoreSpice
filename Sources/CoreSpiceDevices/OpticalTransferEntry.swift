import CoreSpiceIR

/// A linear power transfer coefficient between two optical nodes.
///
/// Used by passive optical devices (waveguides, splitters, couplers) to
/// describe how optical power propagates from input to output. The
/// `OpticalNetworkEvaluator` uses these coefficients to automatically
/// propagate sensitivities via the chain rule:
///
///     dP_out/dV = coefficient × dP_in/dV
///
/// For multi-port devices (e.g., 2×2 MZI couplers), multiple entries
/// describe the full transfer matrix.
public struct OpticalTransferEntry: Sendable {

    /// The input optical node.
    public let inputNode: OpticalNode

    /// The output optical node.
    public let outputNode: OpticalNode

    /// Power transfer coefficient (0...1 for passive devices).
    public let coefficient: Double

    public init(inputNode: OpticalNode, outputNode: OpticalNode, coefficient: Double) {
        self.inputNode = inputNode
        self.outputNode = outputNode
        self.coefficient = coefficient
    }
}
