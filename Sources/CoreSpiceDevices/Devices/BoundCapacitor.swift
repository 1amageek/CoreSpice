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

    /// The initial voltage across the capacitor for transient analysis.
    public let initialVoltage: Double

    /// Whether this capacitor has an explicit initial voltage set.
    public var hasInitialCondition: Bool {
        initialVoltage != 0.0
    }

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        capacitance: Double,
        initialVoltage: Double
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.capacitance = capacitance
        self.initialVoltage = initialVoltage
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
        stamper.stampConductance(node1: posNode, node2: negNode, conductance: geq)

        // History current source: Ieq = geq * V_prev (for backward Euler)
        // For trapezoidal: Ieq = geq * V_prev + I_prev (I_prev = C * dv/dt at previous step)
        let vPrev = state.previousVoltage(at: posNode) - state.previousVoltage(at: negNode)
        let ieq: Double

        switch integration.method {
        case .backwardEuler:
            ieq = geq * vPrev
        case .trapezoidal:
            // Trapezoidal companion: Ieq = Geq * V_prev + I_cap_prev
            // where I_cap_prev is the capacitor current at the previous time step.
            let vPrevPrev = state.twoPreviousVoltage(at: posNode) - state.twoPreviousVoltage(at: negNode)
            let dtPrev = integration.previousTimeStep ?? integration.timeStep
            let iCapPrev = capacitance * (vPrev - vPrevPrev) / dtPrev
            ieq = geq * vPrev + iCapPrev
        }

        // Stamp the equivalent current source
        if let pIdx = stamper.nodeIndex(posNode) {
            stamper.stampRHS(pIdx, ieq)
        }
        if let nIdx = stamper.nodeIndex(negNode) {
            stamper.stampRHS(nIdx, -ieq)
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }
}
