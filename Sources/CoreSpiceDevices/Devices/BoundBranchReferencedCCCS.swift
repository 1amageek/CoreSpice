import CoreSpiceIR

/// A current-controlled current source driven by an existing branch current.
public struct BoundBranchReferencedCCCS: BoundDevice, Sendable {

    public let instance: Instance
    private let posOut: Node
    private let negOut: Node
    private let gain: Double
    private let controlBranch: Branch

    init(
        instance: Instance,
        posOut: Node,
        negOut: Node,
        gain: Double,
        controlBranch: Branch
    ) {
        self.instance = instance
        self.posOut = posOut
        self.negOut = negOut
        self.gain = gain
        self.controlBranch = controlBranch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamp(into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        guard let controlIdx = stamper.branchIndex(controlBranch) else { return }
        let posIdx = stamper.nodeIndex(posOut)
        let negIdx = stamper.nodeIndex(negOut)

        if let posIdx {
            stamper.stampMatrix(posIdx, controlIdx, gain, 0.0)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, controlIdx, -gain, 0.0)
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

    private func stamp(into stamper: inout MatrixStamper) {
        guard let controlIdx = stamper.branchIndex(controlBranch) else { return }
        let posIdx = stamper.nodeIndex(posOut)
        let negIdx = stamper.nodeIndex(negOut)

        if let posIdx {
            stamper.stampMatrix(posIdx, controlIdx, gain)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, controlIdx, -gain)
        }
    }
}
