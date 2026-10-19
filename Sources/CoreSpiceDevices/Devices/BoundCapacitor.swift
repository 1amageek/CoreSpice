import CoreSpiceIR

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
public struct BoundCapacitor: BoundDevice, DCPhysicalResidualContributing, TransientPhysicalResidualContributing, TransientPhysicalResidualEnclosureContributing, VoltageInitialConditionDevice, TransientSessionDevice, Sendable {

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
    public var hasInitialCondition: Bool { hasExplicitInitialCondition || initialVoltage != 0.0 }
    private let hasExplicitInitialCondition: Bool

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
    private let committedCapCurrent: ReactiveResidualHistory

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        capacitance: Double,
        initialVoltage: Double,
        hasExplicitInitialCondition: Bool = false,
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
        self.hasExplicitInitialCondition = hasExplicitInitialCondition
        self.posIdx = posIdx
        self.negIdx = negIdx
        self.stampPP = stampPP
        self.stampNN = stampNN
        self.stampPN = stampPN
        self.stampNP = stampNP
        self.committedCapCurrent = ReactiveResidualHistory()
    }

    public func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        try PhysicalResidualState.validate(try state.checkedVoltage(at: posNode), try state.checkedVoltage(at: negNode))
    }

    public func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
        try accumulatePhysicalResidual(state: state, add: add)
        let history = integration.method == .trapezoidal ? committedCapCurrent.snapshot.ordinary : 0
        let current = try unadjustedOrdinaryDerivative(state: state, integration: integration) - history
        try PhysicalResidualState.validate(current, history, integration.timeStep)
        guard integration.timeStep > 0 else { throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "timeStep", message: "Physical equation requires a positive timestep") }
        if let index = posIdx { add(index, current) }; if let index = negIdx { add(index, -current) }
    }

    public func accumulateTransientPhysicalResidualEnclosure(
        state: SolutionState, integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        let derivative = try unadjustedDerivative(state: state, integration: integration)
        let current = try integration.method == .trapezoidal
            ? derivative.subtracting(committedCapCurrent.snapshot.enclosure) : derivative
        if let index = posIdx { add(index, current.center, current.radius) }
        if let index = negIdx { add(index, current.center.negated(), current.radius) }
    }

    private func unadjustedDerivative(state: SolutionState, integration: IntegrationState) throws -> CompensatedEnclosure {
        let voltage = try PhysicalResidualState.voltageDifference(state, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        let previous = try PhysicalResidualState.previous(state)
        let oldVoltage = try PhysicalResidualState.voltageDifference(previous, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        return try PhysicalResidualState.derivative(voltage.subtracting(oldVoltage),
            coefficient: capacitance, integration: integration)
    }

    public func beginTransientSession(initialState: SolutionState) throws {
        _ = try PhysicalResidualState.voltageDifference(initialState, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        try committedCapCurrent.begin(device: instance.name)
    }

    public func endTransientSession() { committedCapCurrent.end() }

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
            let iCapPrev = committedCapCurrent.snapshot.ordinary
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
    public func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        let derivative = try unadjustedDerivative(state: state, integration: integration)
        let vPos = posIdx.map { state.value(at: $0) } ?? 0.0
        let vNeg = negIdx.map { state.value(at: $0) } ?? 0.0
        let v = vPos - vNeg

        let vPrevPos = posIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vPrevNeg = negIdx.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev = vPrevPos - vPrevNeg

        try committedCapCurrent.update { history in
            let newCurrent: Double
            let precise: CompensatedEnclosure
            switch integration.method {
            case .backwardEuler:
                newCurrent = (capacitance / integration.timeStep) * (v - vPrev)
                precise = derivative
            case .trapezoidal:
                let geq = integration.coefficient * capacitance
                newCurrent = geq * (v - vPrev) - history.ordinary
                precise = try derivative.subtracting(history.enclosure)
            }
            try PhysicalResidualState.validate(newCurrent)
            history.ordinary = newCurrent
            history.center = precise.center
            history.radius = precise.radius
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }
}

extension BoundCapacitor: TransientPhysicalEquationDecomposing, TransientPhysicalEquationEnclosureDecomposing {
    public var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
    public func validateTransientPhysicalEquationDecomposition() throws {
        try PhysicalResidualState.validate(capacitance)
    }
    public func accumulateTransientStaticResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        // The admitted capacitor has identically zero static F.
        try accumulatePhysicalResidual(state: state, add: add)
    }
    public func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
        try accumulateTransientStaticResidual(state: state, time: integration.currentTime) { add($0, .staticResidual, $1) }
        let difference = try unadjustedOrdinaryDerivative(state: state, integration: integration)
        if let posIdx { add(posIdx, .chargeDifference, difference) }
        if let negIdx { add(negIdx, .chargeDifference, -difference) }
    }
    private func unadjustedOrdinaryDerivative(state: SolutionState, integration: IntegrationState) throws -> Double {
        let previous = try PhysicalResidualState.previous(state)
        let voltage = try state.checkedVoltage(at: posNode) - state.checkedVoltage(at: negNode)
        let oldVoltage = try previous.checkedVoltage(at: posNode) - previous.checkedVoltage(at: negNode)
        let difference = capacitance * integration.coefficient * (voltage - oldVoltage)
        try PhysicalResidualState.validate(difference, integration.timeStep)
        guard integration.timeStep > 0 else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "timeStep",
                message: "Original capacitor decomposition requires a positive timestep")
        }
        return difference
    }
    public func accumulateTransientStaticResidualEnclosure(state: SolutionState, time: Double,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        _ = try PhysicalResidualState.voltageDifference(state, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
    }
    public func accumulateTransientPhysicalEquationEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws {
        try PhysicalResidualState.validate(integration.currentTime)
        let difference = try unadjustedDerivative(state: state, integration: integration)
        if let posIdx { add(posIdx, .chargeDifference, difference.center, difference.radius) }
        if let negIdx { add(negIdx, .chargeDifference, difference.center.negated(), difference.radius) }
    }
}

extension BoundCapacitor: ContinuousEquationLinearLawProviding {
    package func visitContinuousEquationLinearLaw(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationLinearTerm) throws -> Void) throws {
        try visitContinuousEquationTwoTerminalLaw(positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx, plane: .charge,
            coefficient: capacitance, device: instance.name, checkpoint: checkpoint, visit: visit)
    }
    package func visitContinuousEquationStructure(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void
    ) throws {
        try visitContinuousEquationNode(posNode, index: posIdx, device: instance.name, access: .readCoordinate, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(negNode, index: negIdx, device: instance.name, access: .readCoordinate, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(posNode, index: posIdx, device: instance.name, access: .writeCharge, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(negNode, index: negIdx, device: instance.name, access: .writeCharge, checkpoint: checkpoint, visit: visit)
    }
}
