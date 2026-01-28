import CoreSpiceIR

/// A current-controlled current source bound to circuit nodes.
///
/// Uses one sensing branch (zero-volt source across the sense terminals)
/// to measure the controlling current. The output current
/// `I_out = f * I_sense` is stamped into the output node equations.
public struct BoundCCCS: BoundDevice, Sendable {

    public let instance: Instance
    private let posOut: Node
    private let negOut: Node
    private let posSense: Node
    private let negSense: Node
    private let gain: Double
    private let senseBranch: Branch

    init(
        instance: Instance,
        posOut: Node,
        negOut: Node,
        posSense: Node,
        negSense: Node,
        gain: Double,
        senseBranch: Branch
    ) {
        self.instance = instance
        self.posOut = posOut
        self.negOut = negOut
        self.posSense = posSense
        self.negSense = negSense
        self.gain = gain
        self.senseBranch = senseBranch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamp(into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        guard let sbIdx = stamper.branchIndex(senseBranch) else { return }
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let psIdx = stamper.nodeIndex(posSense)
        let nsIdx = stamper.nodeIndex(negSense)

        // Sensing branch: zero-volt source across sense terminals
        if let psIdx {
            stamper.stampMatrix(psIdx, sbIdx, 1.0, 0.0)
            stamper.stampMatrix(sbIdx, psIdx, 1.0, 0.0)
        }
        if let nsIdx {
            stamper.stampMatrix(nsIdx, sbIdx, -1.0, 0.0)
            stamper.stampMatrix(sbIdx, nsIdx, -1.0, 0.0)
        }

        // Output current: I_out = f * I_sense
        // KCL contribution to output nodes
        if let poIdx {
            stamper.stampMatrix(poIdx, sbIdx, gain, 0.0)
        }
        if let noIdx {
            stamper.stampMatrix(noIdx, sbIdx, -gain, 0.0)
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
        guard let sbIdx = stamper.branchIndex(senseBranch) else { return }
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let psIdx = stamper.nodeIndex(posSense)
        let nsIdx = stamper.nodeIndex(negSense)

        // Sensing branch: zero-volt source to measure controlling current
        // V(posSense) - V(negSense) = 0
        if let psIdx {
            stamper.stampMatrix(psIdx, sbIdx, 1.0)
            stamper.stampMatrix(sbIdx, psIdx, 1.0)
        }
        if let nsIdx {
            stamper.stampMatrix(nsIdx, sbIdx, -1.0)
            stamper.stampMatrix(sbIdx, nsIdx, -1.0)
        }

        // Output current: I_out = f * I_sense
        // Enters positive output, leaves negative output
        if let poIdx {
            stamper.stampMatrix(poIdx, sbIdx, gain)
        }
        if let noIdx {
            stamper.stampMatrix(noIdx, sbIdx, -gain)
        }
    }
}
