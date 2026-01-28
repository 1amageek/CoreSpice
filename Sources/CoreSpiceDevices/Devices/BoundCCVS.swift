import CoreSpiceIR

/// A current-controlled voltage source bound to circuit nodes.
///
/// Uses two branch variables:
/// - `senseBranch`: measures the controlling current through a zero-volt source
///   across the sensing terminals.
/// - `outputBranch`: carries the output current and enforces
///   `V(pos_out) - V(neg_out) = h * I_sense`.
public struct BoundCCVS: BoundDevice, Sendable {

    public let instance: Instance
    private let posOut: Node
    private let negOut: Node
    private let posSense: Node
    private let negSense: Node
    private let transresistance: Double
    private let senseBranch: Branch
    private let outputBranch: Branch

    init(
        instance: Instance,
        posOut: Node,
        negOut: Node,
        posSense: Node,
        negSense: Node,
        transresistance: Double,
        senseBranch: Branch,
        outputBranch: Branch
    ) {
        self.instance = instance
        self.posOut = posOut
        self.negOut = negOut
        self.posSense = posSense
        self.negSense = negSense
        self.transresistance = transresistance
        self.senseBranch = senseBranch
        self.outputBranch = outputBranch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamp(into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        guard let sbIdx = stamper.branchIndex(senseBranch) else { return }
        guard let obIdx = stamper.branchIndex(outputBranch) else { return }
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let psIdx = stamper.nodeIndex(posSense)
        let nsIdx = stamper.nodeIndex(negSense)

        // Sensing branch: zero-volt source across sense terminals
        // V(posSense) - V(negSense) = 0
        if let psIdx {
            stamper.stampMatrix(psIdx, sbIdx, 1.0, 0.0)
            stamper.stampMatrix(sbIdx, psIdx, 1.0, 0.0)
        }
        if let nsIdx {
            stamper.stampMatrix(nsIdx, sbIdx, -1.0, 0.0)
            stamper.stampMatrix(sbIdx, nsIdx, -1.0, 0.0)
        }

        // Output branch: V(posOut) - V(negOut) = h * I_sense
        // => V(posOut) - V(negOut) - h * I_sense = 0
        if let poIdx {
            stamper.stampMatrix(poIdx, obIdx, 1.0, 0.0)
            stamper.stampMatrix(obIdx, poIdx, 1.0, 0.0)
        }
        if let noIdx {
            stamper.stampMatrix(noIdx, obIdx, -1.0, 0.0)
            stamper.stampMatrix(obIdx, noIdx, -1.0, 0.0)
        }
        stamper.stampMatrix(obIdx, sbIdx, -transresistance, 0.0)
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
        guard let obIdx = stamper.branchIndex(outputBranch) else { return }
        let poIdx = stamper.nodeIndex(posOut)
        let noIdx = stamper.nodeIndex(negOut)
        let psIdx = stamper.nodeIndex(posSense)
        let nsIdx = stamper.nodeIndex(negSense)

        // Sensing branch: zero-volt source measures current
        // KCL for sense nodes
        if let psIdx {
            stamper.stampMatrix(psIdx, sbIdx, 1.0)
            stamper.stampMatrix(sbIdx, psIdx, 1.0)
        }
        if let nsIdx {
            stamper.stampMatrix(nsIdx, sbIdx, -1.0)
            stamper.stampMatrix(sbIdx, nsIdx, -1.0)
        }

        // Output branch equation: V(posOut) - V(negOut) - h * I_sense = 0
        if let poIdx {
            stamper.stampMatrix(poIdx, obIdx, 1.0)
            stamper.stampMatrix(obIdx, poIdx, 1.0)
        }
        if let noIdx {
            stamper.stampMatrix(noIdx, obIdx, -1.0)
            stamper.stampMatrix(obIdx, noIdx, -1.0)
        }
        stamper.stampMatrix(obIdx, sbIdx, -transresistance)
    }
}
