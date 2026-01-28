import CoreSpiceIR

/// A voltage-controlled current source bound to circuit nodes.
///
/// No branch variable is needed. The output current is:
/// `I_out = g * (V(pos_ctrl) - V(neg_ctrl))`
/// stamped directly into the conductance matrix.
public struct BoundVCCS: BoundDevice, Sendable {

    public let instance: Instance
    private let posOut: Node
    private let negOut: Node
    private let posCtrl: Node
    private let negCtrl: Node
    private let transconductance: Double

    init(
        instance: Instance,
        posOut: Node,
        negOut: Node,
        posCtrl: Node,
        negCtrl: Node,
        transconductance: Double
    ) {
        self.instance = instance
        self.posOut = posOut
        self.negOut = negOut
        self.posCtrl = posCtrl
        self.negCtrl = negCtrl
        self.transconductance = transconductance
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamp(into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let pcIdx = stamper.nodeIndex(posCtrl)
        let ncIdx = stamper.nodeIndex(negCtrl)

        // G matrix entries for I = g * (V_ctrl+ - V_ctrl-)
        if let poIdx, let pcIdx {
            stamper.stampMatrix(poIdx, pcIdx, transconductance, 0.0)
        }
        if let poIdx, let ncIdx {
            stamper.stampMatrix(poIdx, ncIdx, -transconductance, 0.0)
        }
        if let noIdx, let pcIdx {
            stamper.stampMatrix(noIdx, pcIdx, -transconductance, 0.0)
        }
        if let noIdx, let ncIdx {
            stamper.stampMatrix(noIdx, ncIdx, transconductance, 0.0)
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stamp(into: &stamper)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }

    // MARK: - Private

    private func stamp(into stamper: inout MatrixStamper) {
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let pcIdx = stamper.nodeIndex(posCtrl)
        let ncIdx = stamper.nodeIndex(negCtrl)

        // G matrix stamp pattern for VCCS:
        // I_out enters pos_out, leaves neg_out
        // I_out = g * (V_ctrl+ - V_ctrl-)
        if let poIdx, let pcIdx {
            stamper.stampMatrix(poIdx, pcIdx, transconductance)
        }
        if let poIdx, let ncIdx {
            stamper.stampMatrix(poIdx, ncIdx, -transconductance)
        }
        if let noIdx, let pcIdx {
            stamper.stampMatrix(noIdx, pcIdx, -transconductance)
        }
        if let noIdx, let ncIdx {
            stamper.stampMatrix(noIdx, ncIdx, transconductance)
        }
    }
}
