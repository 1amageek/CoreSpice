import CoreSpiceIR
import Synchronization

/// Thread-safe mutable storage for a single Double value.
///
/// Used by BoundCapacitor to track the capacitor current across
/// timesteps. Wraps `Mutex<Double>` in a reference type so it can
/// be stored in a Copyable struct.
private final class MutableDouble: Sendable {
    private let storage: Mutex<Double>
    init(_ value: Double) { storage = Mutex(value) }
    var value: Double {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// A capacitor bound to specific circuit nodes.
///
/// DC: open circuit (no stamp).
/// AC: admittance `j * omega * C`.
/// Transient: companion model with equivalent conductance and
/// history-dependent current source.
///
/// The trapezoidal companion model requires the capacitor current
/// from the previous accepted timestep. This is stored in
/// `committedCapCurrent` and updated after each step acceptance
/// via `commitTransientStep(state:integration:)`.
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

    /// Capacitor current from the last accepted timestep.
    ///
    /// The trapezoidal companion model is:
    ///   i_n = (2C/h)(V_n - V_{n-1}) - i_{n-1}
    ///
    /// Without tracking i_{n-1} recursively, approximating it as
    /// C*(V_{n-1}-V_{n-2})/h is only 1st-order accurate, which
    /// degrades the trapezoidal method from O(h²) to O(h).
    private let committedCapCurrent: MutableDouble

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
        self.committedCapCurrent = MutableDouble(0.0)
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
        //   Backward Euler:  Geq = C / dt,   Ieq = Geq * V_prev
        //   Trapezoidal:     Geq = 2C / dt,  Ieq = Geq * V_prev + i_cap_prev
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

        // History current source
        let vPos = posIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vNeg = negIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev = vPos - vNeg
        let ieq: Double

        switch integration.method {
        case .backwardEuler:
            ieq = geq * vPrev
        case .trapezoidal:
            // Trapezoidal companion: Ieq = Geq * V_prev + i_cap_prev
            // where i_cap_prev is the actual capacitor current at the
            // previous accepted timestep, tracked recursively to maintain
            // 2nd-order accuracy.
            let iCapPrev = committedCapCurrent.value
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

    /// Update the stored capacitor current after an accepted timestep.
    ///
    /// Must be called after each accepted transient step so that the
    /// next step's trapezoidal companion model uses the correct i_{n-1}.
    ///
    /// The capacitor current at step n is:
    ///   BE:   i_n = (C/h)(V_n - V_{n-1})
    ///   Trap: i_n = (2C/h)(V_n - V_{n-1}) - i_{n-1}
    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        let vPos = posIdx.map { state.value(at: $0) } ?? 0.0
        let vNeg = negIdx.map { state.value(at: $0) } ?? 0.0
        let v = vPos - vNeg

        let vPrevPos = posIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vPrevNeg = negIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev = vPrevPos - vPrevNeg

        let newCurrent: Double
        switch integration.method {
        case .backwardEuler:
            newCurrent = (capacitance / integration.timeStep) * (v - vPrev)
        case .trapezoidal:
            let geq = integration.coefficient * capacitance
            let iCapPrev = committedCapCurrent.value
            newCurrent = geq * (v - vPrev) - iCapPrev
        }
        committedCapCurrent.value = newCurrent
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }
}
