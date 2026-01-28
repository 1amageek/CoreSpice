import CoreSpiceIR

/// A voltage-controlled voltage source bound to circuit nodes.
///
/// Branch equation: `V(pos_out) - V(neg_out) - e * (V(pos_ctrl) - V(neg_ctrl)) = 0`
/// where `e` is the voltage gain.
public struct BoundVCVS: BoundDevice, Sendable {

    public let instance: Instance
    private let posOut: Node
    private let negOut: Node
    private let posCtrl: Node
    private let negCtrl: Node
    private let gain: Double
    private let branch: Branch

    init(
        instance: Instance,
        posOut: Node,
        negOut: Node,
        posCtrl: Node,
        negCtrl: Node,
        gain: Double,
        branch: Branch
    ) {
        self.instance = instance
        self.posOut = posOut
        self.negOut = negOut
        self.posCtrl = posCtrl
        self.negCtrl = negCtrl
        self.gain = gain
        self.branch = branch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamp(into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        guard let bIdx = stamper.branchIndex(branch) else { return }
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let pcIdx = stamper.nodeIndex(posCtrl)
        let ncIdx = stamper.nodeIndex(negCtrl)

        // KCL: branch current contribution
        if let poIdx {
            stamper.stampMatrix(poIdx, bIdx, 1.0, 0.0)
        }
        if let noIdx {
            stamper.stampMatrix(noIdx, bIdx, -1.0, 0.0)
        }

        // Branch equation: V(posOut) - V(negOut) - e * V(posCtrl) + e * V(negCtrl) = 0
        if let poIdx {
            stamper.stampMatrix(bIdx, poIdx, 1.0, 0.0)
        }
        if let noIdx {
            stamper.stampMatrix(bIdx, noIdx, -1.0, 0.0)
        }
        if let pcIdx {
            stamper.stampMatrix(bIdx, pcIdx, -gain, 0.0)
        }
        if let ncIdx {
            stamper.stampMatrix(bIdx, ncIdx, gain, 0.0)
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
        guard let bIdx = stamper.branchIndex(branch) else { return }
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let pcIdx = stamper.nodeIndex(posCtrl)
        let ncIdx = stamper.nodeIndex(negCtrl)

        // KCL: branch current enters positive output, leaves negative output
        if let poIdx {
            stamper.stampMatrix(poIdx, bIdx, 1.0)
        }
        if let noIdx {
            stamper.stampMatrix(noIdx, bIdx, -1.0)
        }

        // Branch equation: V(posOut) - V(negOut) - e * (V(posCtrl) - V(negCtrl)) = 0
        if let poIdx {
            stamper.stampMatrix(bIdx, poIdx, 1.0)
        }
        if let noIdx {
            stamper.stampMatrix(bIdx, noIdx, -1.0)
        }
        if let pcIdx {
            stamper.stampMatrix(bIdx, pcIdx, -gain)
        }
        if let ncIdx {
            stamper.stampMatrix(bIdx, ncIdx, gain)
        }
    }
}
