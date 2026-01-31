import Foundation
import CoreSpiceIR
import CoreSpiceDevices

/// A 1x2 optical power splitter bound to optical nodes.
///
/// Splits the input optical signal into two outputs with a configurable
/// split ratio and optional excess loss.
///
/// Power conservation: `P_out1 + P_out2 = P_in * (1 - excess_loss)`
///
/// For a 50:50 splitter: each output gets `P_in * 0.5 * (1 - excess_loss)`.
public struct BoundOpticalSplitter: OpticalDevice, Sendable {

    public let instance: Instance

    private let inputNode: OpticalNode
    private let outputNode1: OpticalNode
    private let outputNode2: OpticalNode

    /// Fraction of power to output 1 (0..1). Output 2 gets the complement.
    private let splitRatio: Double

    /// Excess insertion loss as a linear factor (0 = no loss, 0.05 = 5% excess loss).
    private let excessLoss: Double

    /// Field amplitude coefficient for output 1.
    private let fieldCoeff1: Double

    /// Field amplitude coefficient for output 2.
    private let fieldCoeff2: Double

    public var opticalInputNodes: [OpticalNode] { [inputNode] }
    public var opticalOutputNodes: [OpticalNode] { [outputNode1, outputNode2] }

    public init(
        instance: Instance,
        inputNode: OpticalNode,
        outputNode1: OpticalNode,
        outputNode2: OpticalNode,
        splitRatio: Double = 0.5,
        excessLoss: Double = 0.0
    ) {
        self.instance = instance
        self.inputNode = inputNode
        self.outputNode1 = outputNode1
        self.outputNode2 = outputNode2
        self.splitRatio = splitRatio
        self.excessLoss = excessLoss

        // Field amplitude = sqrt(power ratio * (1 - excess_loss))
        let throughput = 1.0 - excessLoss
        self.fieldCoeff1 = (splitRatio * throughput).squareRoot()
        self.fieldCoeff2 = ((1.0 - splitRatio) * throughput).squareRoot()
    }

    // MARK: - OpticalDevice

    public func propagate(inputs: [OpticalNode: OpticalSignal]) -> [OpticalNode: OpticalSignal] {
        guard let input = inputs[inputNode] else {
            return [outputNode1: .zero, outputNode2: .zero]
        }

        let out1 = OpticalSignal(
            re: fieldCoeff1 * input.re,
            im: fieldCoeff1 * input.im,
            wavelength: input.wavelength
        )
        let out2 = OpticalSignal(
            re: fieldCoeff2 * input.re,
            im: fieldCoeff2 * input.im,
            wavelength: input.wavelength
        )

        return [outputNode1: out1, outputNode2: out2]
    }

    public func transferCoefficients() -> [OpticalTransferEntry] {
        // Power transfer coefficients for sensitivity propagation
        let throughput = 1.0 - excessLoss
        return [
            OpticalTransferEntry(
                inputNode: inputNode,
                outputNode: outputNode1,
                coefficient: splitRatio * throughput
            ),
            OpticalTransferEntry(
                inputNode: inputNode,
                outputNode: outputNode2,
                coefficient: (1.0 - splitRatio) * throughput
            )
        ]
    }

    // MARK: - BoundDevice (no-op for purely optical device)

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {}
    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {}
    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {}

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}
