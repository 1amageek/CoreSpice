import CoreSpiceIR

/// An inductor bound to specific circuit nodes and a branch variable.
///
/// DC: short circuit (zero voltage across, branch current is a variable).
/// AC: impedance `j * omega * L` (stamped via branch equation).
/// Transient: companion model with equivalent resistance and
/// history-dependent voltage source.
public struct BoundInductor: BoundDevice, CurrentInitialConditionDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let inductance: Double

    /// The initial current through the inductor for transient analysis.
    public let initialCurrent: Double

    private let branch: Branch

    /// Whether this inductor has an explicit initial current set.
    public var hasInitialCondition: Bool {
        initialCurrent != 0.0
    }

    public var deviceBranch: Branch { branch }

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        inductance: Double,
        initialCurrent: Double,
        branch: Branch
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.inductance = inductance
        self.initialCurrent = initialCurrent
        self.branch = branch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // At DC an inductor is a short circuit: V(pos) - V(neg) = 0
        stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: 0.0)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Branch equation: V(pos) - V(neg) = j * omega * L * I_branch
        guard let bIdx = stamper.branchIndex(branch) else { return }
        let pIdx = stamper.nodeIndex(posNode)
        let nIdx = stamper.nodeIndex(negNode)

        // KCL: node equations include branch current
        if let pIdx {
            stamper.stampMatrix(pIdx, bIdx, 1.0, 0.0)
        }
        if let nIdx {
            stamper.stampMatrix(nIdx, bIdx, -1.0, 0.0)
        }

        // KVL: V(pos) - V(neg) - j*omega*L * I_branch = 0
        if let pIdx {
            stamper.stampMatrix(bIdx, pIdx, 1.0, 0.0)
        }
        if let nIdx {
            stamper.stampMatrix(bIdx, nIdx, -1.0, 0.0)
        }
        // The -j*omega*L term on the branch current
        stamper.stampMatrix(bIdx, bIdx, 0.0, -omega * inductance)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        // Companion model for inductor:
        //   Backward Euler:  Req = L / dt,   Veq = L / dt * I_prev
        //   Trapezoidal:     Req = 2L / dt,  Veq = 2L / dt * I_prev + V_prev
        //
        // The inductor branch equation becomes:
        //   V(pos) - V(neg) = Req * I_branch - Veq
        //   Rewritten: V(pos) - V(neg) - Req * I_branch = -Veq
        guard let bIdx = stamper.branchIndex(branch) else { return }
        let pIdx = stamper.nodeIndex(posNode)
        let nIdx = stamper.nodeIndex(negNode)

        let req = inductance * integration.coefficient

        // KCL: branch current enters positive node
        if let pIdx {
            stamper.stampMatrix(pIdx, bIdx, 1.0)
        }
        if let nIdx {
            stamper.stampMatrix(nIdx, bIdx, -1.0)
        }

        // KVL: V(pos) - V(neg) - Req * I_branch = -Veq
        if let pIdx {
            stamper.stampMatrix(bIdx, pIdx, 1.0)
        }
        if let nIdx {
            stamper.stampMatrix(bIdx, nIdx, -1.0)
        }
        stamper.stampMatrix(bIdx, bIdx, -req)

        // History source
        let iPrev = state.previousCurrent(through: branch)
        let veq: Double
        switch integration.method {
        case .backwardEuler:
            veq = req * iPrev
        case .trapezoidal:
            let vPrev = state.previousVoltage(at: posNode) - state.previousVoltage(at: negNode)
            veq = req * iPrev + vPrev
        }

        stamper.stampRHS(bIdx, -veq)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }
}
