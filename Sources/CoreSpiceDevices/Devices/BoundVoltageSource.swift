import CoreSpiceIR

/// A voltage source bound to specific circuit nodes and a branch variable.
///
/// The voltage source imposes `V(pos) - V(neg) = V` and introduces
/// a branch current variable into the MNA system.
public struct BoundVoltageSource: BoundDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let dcVoltage: Double
    private let acMagnitude: Double
    private let waveform: Waveform
    private let branch: Branch

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        dcVoltage: Double,
        acMagnitude: Double,
        waveform: Waveform,
        branch: Branch
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.dcVoltage = dcVoltage
        self.acMagnitude = acMagnitude
        self.waveform = waveform
        self.branch = branch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: dcVoltage)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // AC voltage source: stamp the branch equation topology with
        // the AC stimulus magnitude as a real-valued RHS.
        stamper.stampVoltageSource(
            posNode: posNode, negNode: negNode, branch: branch,
            real: acMagnitude, imag: 0.0
        )
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        let voltage = waveform.value(at: integration.currentTime)
        stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: voltage)
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
    ///   - factor: Scaling factor (0.0 to 1.0) applied to the source voltage.
    public func stampDCScaled(into stamper: inout MatrixStamper, state: SolutionState, factor: Double) {
        let scaledVoltage = dcVoltage * factor
        stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: scaledVoltage)
    }
}
