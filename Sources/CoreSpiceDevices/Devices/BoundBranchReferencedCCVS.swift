import CoreSpiceIR

/// A current-controlled voltage source driven by an existing branch current.
public struct BoundBranchReferencedCCVS: BoundDevice, Sendable {

    public let instance: Instance
    private let posOut: Node
    private let negOut: Node
    private let transresistance: Double
    private let controlBranch: Branch
    private let outputBranch: Branch

    init(
        instance: Instance,
        posOut: Node,
        negOut: Node,
        transresistance: Double,
        controlBranch: Branch,
        outputBranch: Branch
    ) {
        self.instance = instance
        self.posOut = posOut
        self.negOut = negOut
        self.transresistance = transresistance
        self.controlBranch = controlBranch
        self.outputBranch = outputBranch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamp(into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        guard let controlIdx = stamper.branchIndex(controlBranch) else { return }
        guard let outputIdx = stamper.branchIndex(outputBranch) else { return }
        let posIdx = stamper.nodeIndex(posOut)
        let negIdx = stamper.nodeIndex(negOut)

        if let posIdx {
            stamper.stampMatrix(posIdx, outputIdx, 1.0, 0.0)
            stamper.stampMatrix(outputIdx, posIdx, 1.0, 0.0)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, outputIdx, -1.0, 0.0)
            stamper.stampMatrix(outputIdx, negIdx, -1.0, 0.0)
        }
        stamper.stampMatrix(outputIdx, controlIdx, -transresistance, 0.0)
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
        guard let outputIdx = stamper.branchIndex(outputBranch) else { return }
        let posIdx = stamper.nodeIndex(posOut)
        let negIdx = stamper.nodeIndex(negOut)

        if let posIdx {
            stamper.stampMatrix(posIdx, outputIdx, 1.0)
            stamper.stampMatrix(outputIdx, posIdx, 1.0)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, outputIdx, -1.0)
            stamper.stampMatrix(outputIdx, negIdx, -1.0)
        }
        stamper.stampMatrix(outputIdx, controlIdx, -transresistance)
    }
}
