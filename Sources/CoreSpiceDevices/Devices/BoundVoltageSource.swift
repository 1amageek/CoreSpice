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
    private let waveform: Waveform
    private let branch: Branch

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        dcVoltage: Double,
        waveform: Waveform,
        branch: Branch
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.dcVoltage = dcVoltage
        self.waveform = waveform
        self.branch = branch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: dcVoltage)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // AC voltage source: same structure as DC but the stimulus
        // magnitude is set during AC analysis setup (typically 1V for the source under test, 0 otherwise).
        // Here we stamp the branch equation topology with zero RHS.
        stamper.stampVoltageSource(
            posNode: posNode, negNode: negNode, branch: branch,
            real: 0.0, imag: 0.0
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
}
