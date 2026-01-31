import CoreSpiceIR

/// A capacitor bound to specific circuit nodes.
///
/// DC: open circuit (no stamp).
/// AC: admittance `j * omega * C`.
/// Transient: companion model with equivalent conductance and
/// history-dependent current source.
public struct BoundCapacitor: BoundDevice, VoltageInitialConditionDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let capacitance: Double

    /// Pre-resolved matrix index for the positive node (nil for ground).
    private let posIdx: Int?
    /// Pre-resolved matrix index for the negative node (nil for ground).
    private let negIdx: Int?

    /// Pre-resolved CSR value indices for O(1) stamping.
    private let stampPP: Int?
    private let stampNN: Int?
    private let stampPN: Int?
    private let stampNP: Int?

    /// The initial voltage across the capacitor for transient analysis.
    public let initialVoltage: Double

    /// Whether this capacitor has an explicit initial voltage set.
    public var hasInitialCondition: Bool {
        initialVoltage != 0.0
    }

    public var positiveNode: Node { posNode }
    public var negativeNode: Node { negNode }

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        capacitance: Double,
        initialVoltage: Double,
        posIdx: Int?,
        negIdx: Int?,
        stampPP: Int? = nil,
        stampNN: Int? = nil,
        stampPN: Int? = nil,
        stampNP: Int? = nil
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.capacitance = capacitance
        self.initialVoltage = initialVoltage
        self.posIdx = posIdx
        self.negIdx = negIdx
        self.stampPP = stampPP
        self.stampNN = stampNN
        self.stampPN = stampPN
        self.stampNP = stampNP
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // A capacitor is an open circuit at DC; no stamp needed.
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Admittance Y = j * omega * C
        stamper.stampAdmittance(node1: posNode, node2: negNode, real: 0.0, imag: omega * capacitance)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        // Companion model:
        //   Backward Euler:  Geq = C / dt,   Ieq = C / dt * V_prev
        //   Trapezoidal:     Geq = 2C / dt,  Ieq = 2C / dt * V_prev + I_prev
        //
        // In both cases, Geq = coefficient * C.
        let geq = integration.coefficient * capacitance

        // Stamp equivalent conductance (fast path when CSR indices available)
        if let sv = stamper.stampValue, stampPP != nil || stampNN != nil {
            if let idx = stampPP { sv(idx, geq) }
            if let idx = stampNN { sv(idx, geq) }
            if let idx = stampPN { sv(idx, -geq) }
            if let idx = stampNP { sv(idx, -geq) }
        } else {
            stamper.stampConductance(node1: posNode, node2: negNode, conductance: geq)
        }

        // History current source: Ieq = geq * V_prev (for backward Euler)
        // For trapezoidal: Ieq = geq * V_prev + I_prev (I_prev = C * dv/dt at previous step)
        let vPos = posIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vNeg = negIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev = vPos - vNeg
        let ieq: Double

        switch integration.method {
        case .backwardEuler:
            ieq = geq * vPrev
        case .trapezoidal:
            // Trapezoidal companion: Ieq = Geq * V_prev + I_cap_prev
            // where I_cap_prev is the capacitor current at the previous time step.
            let vPosPP = posIdx.map { state.twoPreviousValue(at: $0) } ?? 0.0
            let vNegPP = negIdx.map { state.twoPreviousValue(at: $0) } ?? 0.0
            let vPrevPrev = vPosPP - vNegPP
            let dtPrev = integration.previousTimeStep ?? integration.timeStep
            let iCapPrev = capacitance * (vPrev - vPrevPrev) / dtPrev
            ieq = geq * vPrev + iCapPrev
        }

        // Stamp the equivalent current source (use pre-resolved indices)
        if let pIdx = posIdx {
            stamper.stampRHS(pIdx, ieq)
        }
        if let nIdx = negIdx {
            stamper.stampRHS(nIdx, -ieq)
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }
}
