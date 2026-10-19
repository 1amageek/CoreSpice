import CoreSpiceIR

/// An inductor bound to specific circuit nodes and a branch variable.
///
/// DC: short circuit (zero voltage across, branch current is a variable).
/// AC: impedance `j * omega * L` (stamped via branch equation).
/// Transient: companion model with equivalent resistance and
/// history-dependent voltage source.
public struct BoundInductor: BoundDevice, DCPhysicalResidualContributing, TransientPhysicalResidualContributing, TransientPhysicalResidualEnclosureContributing, CurrentInitialConditionDevice, TransientSessionDevice, Sendable {

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
    private let committedDerivative = ReactiveResidualHistory()

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

    public func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        guard let branchIdx else { throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch", message: "Direct residual requires a bound branch") }
        let current = try state.checkedBoundValue(at: branchIdx, for: .branchCurrent(branch))
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        let voltage = try state.checkedVoltage(at: posNode) - state.checkedVoltage(at: negNode)
        try PhysicalResidualState.validate(current, voltage)
        if let index = posIdx { add(index, current) }; if let index = negIdx { add(index, -current) }
        add(branchIdx, voltage)
    }

    public func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
        guard let branchIdx else { throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch", message: "Direct residual requires a bound branch") }
        let previous = try PhysicalResidualState.previous(state)
        let current = try state.checkedBoundValue(at: branchIdx, for: .branchCurrent(branch))
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        let voltage = try state.checkedVoltage(at: posNode) - state.checkedVoltage(at: negNode)
        let oldVoltage = integration.method == .trapezoidal ? try previous.checkedVoltage(at: posNode) - previous.checkedVoltage(at: negNode) : 0
        let residual = try voltage - unadjustedOrdinaryDerivative(state: state, integration: integration) + oldVoltage
        try PhysicalResidualState.validate(current, residual, integration.timeStep)
        guard integration.timeStep > 0 else { throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "timeStep", message: "Physical equation requires a positive timestep") }
        if let index = posIdx { add(index, current) }; if let index = negIdx { add(index, -current) }
        add(branchIdx, residual)
    }

    public func accumulateTransientPhysicalResidualEnclosure(
        state: SolutionState, integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        guard let branchIdx else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch",
                message: "Enclosed inductor equation requires a bound branch")
        }
        let current = try PhysicalResidualState.current(state, branch: branch, index: branchIdx)
        let voltage = try PhysicalResidualState.voltageDifference(state, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        let derivative = try unadjustedDerivative(state: state, integration: integration)
        let adjusted = try integration.method == .trapezoidal
            ? derivative.subtracting(committedDerivative.snapshot.enclosure) : derivative
        let residual = try voltage.subtracting(adjusted)
        if let index = posIdx { add(index, current.center, current.radius) }
        if let index = negIdx { add(index, current.center.negated(), current.radius) }
        add(branchIdx, residual.center, residual.radius)
    }

    private func unadjustedDerivative(state: SolutionState, integration: IntegrationState) throws -> CompensatedEnclosure {
        guard let branchIdx else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch",
                message: "Enclosed inductor equation requires a bound branch")
        }
        let current = try PhysicalResidualState.current(state, branch: branch, index: branchIdx)
        let previous = try PhysicalResidualState.previous(state)
        let oldCurrent = try PhysicalResidualState.current(previous, branch: branch, index: branchIdx)
        return try PhysicalResidualState.derivative(current.subtracting(oldCurrent),
            coefficient: inductance, integration: integration)
    }

    public func beginTransientSession(initialState: SolutionState) throws {
        guard let branchIdx else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch",
                message: "Enclosed inductor equation requires a bound branch")
        }
        _ = try PhysicalResidualState.current(initialState, branch: branch, index: branchIdx)
        _ = try PhysicalResidualState.voltageDifference(initialState, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        try committedDerivative.begin(device: instance.name)
    }

    public func endTransientSession() { committedDerivative.end() }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        let derivative = try unadjustedDerivative(state: state, integration: integration)
        try committedDerivative.update { history in
            let precise = try integration.method == .trapezoidal
                ? derivative.subtracting(history.enclosure) : derivative
            history.center = precise.center
            history.radius = precise.radius
        }
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

extension BoundInductor: TransientPhysicalEquationDecomposing, TransientPhysicalEquationEnclosureDecomposing {
    public var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
    public func validateTransientPhysicalEquationDecomposition() throws {
        guard branchIdx != nil else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch",
                message: "Original inductor decomposition requires a bound branch")
        }
        try PhysicalResidualState.validate(inductance)
    }
    public func accumulateTransientStaticResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        try accumulatePhysicalResidual(state: state, add: add)
    }
    public func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
        try validateTransientPhysicalEquationDecomposition()
        let branchIdx = try decompositionBranchIndex()
        let difference = try unadjustedOrdinaryDerivative(state: state, integration: integration)
        try accumulateTransientStaticResidual(state: state, time: integration.currentTime) { add($0, .staticResidual, $1) }
        add(branchIdx, .chargeDifference, -difference)
    }
    private func decompositionBranchIndex() throws -> Int {
        guard let branchIdx else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch",
                message: "Original inductor decomposition requires a bound branch")
        }
        return branchIdx
    }
    private func unadjustedOrdinaryDerivative(state: SolutionState, integration: IntegrationState) throws -> Double {
        let branchIdx = try decompositionBranchIndex()
        let previous = try PhysicalResidualState.previous(state)
        let current = try state.checkedBoundValue(at: branchIdx, for: .branchCurrent(branch))
        let oldCurrent = try previous.checkedBoundValue(at: branchIdx, for: .branchCurrent(branch))
        let difference = inductance * integration.coefficient * (current - oldCurrent)
        try PhysicalResidualState.validate(difference, integration.timeStep)
        guard integration.timeStep > 0 else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "timeStep",
                message: "Original inductor decomposition requires a positive timestep")
        }
        return difference
    }
    public func accumulateTransientStaticResidualEnclosure(state: SolutionState, time: Double,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        try validateTransientPhysicalEquationDecomposition()
        let branchIdx = try decompositionBranchIndex()
        try PhysicalResidualState.validate(time)
        let current = try PhysicalResidualState.current(state, branch: branch, index: branchIdx)
        let voltage = try PhysicalResidualState.voltageDifference(state, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        if let posIdx { add(posIdx, current.center, current.radius) }
        if let negIdx { add(negIdx, current.center.negated(), current.radius) }
        add(branchIdx, voltage.center, voltage.radius)
    }
    public func accumulateTransientPhysicalEquationEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws {
        let difference = try unadjustedDerivative(state: state, integration: integration)
        try accumulateTransientStaticResidualEnclosure(state: state, time: integration.currentTime) {
            add($0, .staticResidual, $1, $2)
        }
        let branchIdx = try decompositionBranchIndex()
        add(branchIdx, .chargeDifference, difference.center.negated(), difference.radius)
    }
}
