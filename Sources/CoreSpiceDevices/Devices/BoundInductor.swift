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

    /// Pre-resolved matrix index for the positive node (nil for ground).
    private let posIdx: Int?
    /// Pre-resolved matrix index for the negative node (nil for ground).
    private let negIdx: Int?
    /// Pre-resolved matrix index for the branch current variable (nil when unresolved).
    private let branchIdx: Int?

    /// Pre-resolved CSR value indices for O(1) stamping.
    private let stampPB: Int?
    private let stampBP: Int?
    private let stampNB: Int?
    private let stampBN: Int?
    private let stampBB: Int?

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
        branch: Branch,
        posIdx: Int?,
        negIdx: Int?,
        branchIdx: Int?,
        stampPB: Int? = nil,
        stampBP: Int? = nil,
        stampNB: Int? = nil,
        stampBN: Int? = nil,
        stampBB: Int? = nil
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.inductance = inductance
        self.initialCurrent = initialCurrent
        self.branch = branch
        self.posIdx = posIdx
        self.negIdx = negIdx
        self.branchIdx = branchIdx
        self.stampPB = stampPB
        self.stampBP = stampBP
        self.stampNB = stampNB
        self.stampBN = stampBN
        self.stampBB = stampBB
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // At DC an inductor is a short circuit: V(pos) - V(neg) = 0
        if let sv = stamper.stampValue, let bIdx = branchIdx, stampPB != nil || stampBP != nil {
            if let idx = stampPB { sv(idx, 1.0) }
            if let idx = stampBP { sv(idx, 1.0) }
            if let idx = stampNB { sv(idx, -1.0) }
            if let idx = stampBN { sv(idx, -1.0) }
            stamper.stampRHS(bIdx, 0.0)
        } else {
            stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: 0.0)
        }
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
        guard let bIdx_resolved = branchIdx ?? stamper.branchIndex(branch) else { return }
        let pIdx_resolved = posIdx ?? stamper.nodeIndex(posNode)
        let nIdx_resolved = negIdx ?? stamper.nodeIndex(negNode)

        let req = inductance * integration.coefficient

        if let sv = stamper.stampValue, stampPB != nil || stampBP != nil {
            // Fast path: use pre-resolved CSR value indices
            if let idx = stampPB { sv(idx, 1.0) }
            if let idx = stampNB { sv(idx, -1.0) }
            if let idx = stampBP { sv(idx, 1.0) }
            if let idx = stampBN { sv(idx, -1.0) }
            if let idx = stampBB { sv(idx, -req) }
        } else {
            // Standard path: use stamper matrix operations
            if let pIdx = pIdx_resolved {
                stamper.stampMatrix(pIdx, bIdx_resolved, 1.0)
            }
            if let nIdx = nIdx_resolved {
                stamper.stampMatrix(nIdx, bIdx_resolved, -1.0)
            }
            if let pIdx = pIdx_resolved {
                stamper.stampMatrix(bIdx_resolved, pIdx, 1.0)
            }
            if let nIdx = nIdx_resolved {
                stamper.stampMatrix(bIdx_resolved, nIdx, -1.0)
            }
            stamper.stampMatrix(bIdx_resolved, bIdx_resolved, -req)
        }

        // History source (index-based when available, dictionary fallback otherwise)
        let resolvedBranchIdx = branchIdx ?? bIdx_resolved
        let iPrev = state.previousValue(at: resolvedBranchIdx)
        let veq: Double
        switch integration.method {
        case .backwardEuler:
            veq = req * iPrev
        case .trapezoidal:
            let vPos = posIdx.map { state.previousValue(at: $0) } ?? 0.0
            let vNeg = negIdx.map { state.previousValue(at: $0) } ?? 0.0
            let vPrev = vPos - vNeg
            veq = req * iPrev + vPrev
        }

        stamper.stampRHS(bIdx_resolved, -veq)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }
}
