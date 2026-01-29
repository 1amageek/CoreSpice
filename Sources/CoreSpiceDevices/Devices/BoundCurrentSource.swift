import CoreSpiceIR

/// A current source bound to specific circuit nodes.
///
/// Current flows from the negative terminal to the positive terminal
/// (conventional current enters the positive node).
/// No branch variable is needed; only the RHS is stamped.
public struct BoundCurrentSource: BoundDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let dcCurrent: Double
    private let waveform: Waveform

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        dcCurrent: Double,
        waveform: Waveform
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.dcCurrent = dcCurrent
        self.waveform = waveform
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamper.stampCurrentSource(posNode: posNode, negNode: negNode, current: dcCurrent)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // AC current source: the stimulus is configured separately.
        // Here we stamp zero (the source is off unless it is the test source).
        stamper.stampCurrentSource(posNode: posNode, negNode: negNode, real: 0.0, imag: 0.0)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        let current = waveform.value(at: integration.currentTime)
        stamper.stampCurrentSource(posNode: posNode, negNode: negNode, current: current)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }

    public func breakpoints(in interval: ClosedRange<Double>) -> [Double] {
        waveform.breakpoints(in: interval)
    }

    /// Stamp with a scaling factor for source stepping convergence aid.
    ///
    /// - Parameters:
    ///   - stamper: The matrix stamper to use.
    ///   - state: The current solution state.
    ///   - factor: Scaling factor (0.0 to 1.0) applied to the source current.
    public func stampDCScaled(into stamper: inout MatrixStamper, state: SolutionState, factor: Double) {
        let scaledCurrent = dcCurrent * factor
        stamper.stampCurrentSource(posNode: posNode, negNode: negNode, current: scaledCurrent)
    }
}
