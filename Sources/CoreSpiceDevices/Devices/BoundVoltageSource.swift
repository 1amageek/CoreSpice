import CoreSpiceIR
import Foundation

/// A voltage source bound to specific circuit nodes and a branch variable.
///
/// The voltage source imposes `V(pos) - V(neg) = V` and introduces
/// a branch current variable into the MNA system.
public struct BoundVoltageSource: BoundDevice, TransientPhysicalResidualContributing, TransientPhysicalResidualEnclosureContributing, DCPhysicalResidualContributing, DCPhysicalResidualEnclosureContributing, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let dcVoltage: Double
    private let acMagnitude: Double
    private let acPhaseDegrees: Double
    private let waveform: Waveform
    private let branch: Branch

    // Pre-resolved matrix indices for O(1) stamping
    private let posIdx: Int?
    private let negIdx: Int?
    private let branchIdx: Int?

    // Pre-resolved CSR value indices for direct array access
    private let stampPB: Int?
    private let stampBP: Int?
    private let stampNB: Int?
    private let stampBN: Int?

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        dcVoltage: Double,
        acMagnitude: Double,
        acPhaseDegrees: Double = 0,
        waveform: Waveform,
        branch: Branch,
        posIdx: Int? = nil,
        negIdx: Int? = nil,
        branchIdx: Int? = nil,
        stampPB: Int? = nil,
        stampBP: Int? = nil,
        stampNB: Int? = nil,
        stampBN: Int? = nil
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.dcVoltage = dcVoltage
        self.acMagnitude = acMagnitude
        self.acPhaseDegrees = acPhaseDegrees.truncatingRemainder(dividingBy: 360)
        self.waveform = waveform
        self.branch = branch
        self.posIdx = posIdx
        self.negIdx = negIdx
        self.branchIdx = branchIdx
        self.stampPB = stampPB
        self.stampBP = stampBP
        self.stampNB = stampNB
        self.stampBN = stampBN
    }

    public func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        let values = try pointResidualValues(state: state, voltage: dcVoltage)
        if let index = posIdx { add(index, values.current) }
        if let index = negIdx { add(index, -values.current) }
        add(values.branchRow, values.residual)
    }

    private func sourceEquation(state: SolutionState, voltage: Double) throws -> Double {
        try state.checkedVoltage(at: posNode) - state.checkedVoltage(at: negNode) - voltage
    }

    private func pointResidualValues(state: SolutionState, voltage: Double) throws
        -> (current: Double, residual: Double, branchRow: Int) {
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        guard let branchIdx else { throw DeviceBindingError.invalidParameterValue(device: instance.name,
            parameter: "branch", message: "Direct DC residual requires a bound branch") }
        let current = try state.checkedBoundValue(at: branchIdx, for: .branchCurrent(branch))
        let residual = try sourceEquation(state: state, voltage: voltage)
        guard current.isFinite, residual.isFinite else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name,
                parameter: "dcResidual", message: "Physical DC source equation is nonfinite")
        }
        return (current, residual, branchIdx)
    }

    public func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
        try accumulateStaticSourceResidual(state: state, time: integration.currentTime, add: add)
    }

    public func accumulateTransientPhysicalResidualEnclosure(
        state: SolutionState, integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        try PhysicalResidualState.validate(integration.currentTime)
        try accumulateResidualEnclosure(state: state,
            voltage: PhysicalResidualState.scalar(waveform.value(at: integration.currentTime)), add: add)
    }

    public func accumulatePhysicalResidualEnclosure(
        state: SolutionState, sourceScale: Double, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        guard sourceScale.isFinite, (0...1).contains(sourceScale) else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "sourceScale",
                message: "DC source scale must be finite and within zero and one")
        }
        let voltage = try PhysicalResidualState.scalar(dcVoltage)
            .multiplied(by: PhysicalResidualState.scalar(sourceScale))
        try accumulateResidualEnclosure(state: state, voltage: voltage, add: add)
    }

    private func accumulateResidualEnclosure(
        state: SolutionState, voltage excitation: CompensatedEnclosure,
        add: (Int, CompensatedValue, Double) throws -> Void
    ) throws {
        guard let branchIdx else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch",
                message: "Enclosed source equation requires a bound branch")
        }
        let current = try PhysicalResidualState.current(state, branch: branch, index: branchIdx)
        let voltage = try PhysicalResidualState.voltageDifference(state, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        let residual = try voltage.subtracting(excitation)
        if let index = posIdx { try add(index, current.center, current.radius) }
        if let index = negIdx { try add(index, current.center.negated(), current.radius) }
        try add(branchIdx, residual.center, residual.radius)
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        if let sv = stamper.stampValue, let bIdx = branchIdx, stampPB != nil || stampBP != nil {
            if let idx = stampPB { sv(idx, 1.0) }
            if let idx = stampBP { sv(idx, 1.0) }
            if let idx = stampNB { sv(idx, -1.0) }
            if let idx = stampBN { sv(idx, -1.0) }
            stamper.stampRHS(bIdx, dcVoltage)
        } else {
            stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: dcVoltage)
        }
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // AC voltage source: stamp the branch equation topology with
        // the AC stimulus magnitude as a real-valued RHS.
        stamper.stampVoltageSource(
            posNode: posNode, negNode: negNode, branch: branch,
            real: acMagnitude * cos(acPhaseDegrees * .pi / 180), imag: acMagnitude * sin(acPhaseDegrees * .pi / 180)
        )
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        let voltage = waveform.value(at: integration.currentTime)
        if let sv = stamper.stampValue, let bIdx = branchIdx, stampPB != nil || stampBP != nil {
            if let idx = stampPB { sv(idx, 1.0) }
            if let idx = stampBP { sv(idx, 1.0) }
            if let idx = stampNB { sv(idx, -1.0) }
            if let idx = stampBN { sv(idx, -1.0) }
            stamper.stampRHS(bIdx, voltage)
        } else {
            stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: voltage)
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges.
        .converged
    }

    public func breakpoints(in interval: ClosedRange<Double>, maximumCount: Int) throws -> [Double] {
        try waveform.breakpoints(in: interval, maximumCount: maximumCount)
    }

    /// Stamp with a scaling factor for source stepping convergence aid.
    ///
    /// - Parameters:
    ///   - stamper: The matrix stamper to use.
    ///   - state: The current solution state.
    ///   - factor: Scaling factor (0.0 to 1.0) applied to the source voltage.
    public func stampDCScaled(into stamper: inout MatrixStamper, state: SolutionState, factor: Double) {
        let scaledVoltage = dcVoltage * factor
        if let sv = stamper.stampValue, let bIdx = branchIdx, stampPB != nil || stampBP != nil {
            if let idx = stampPB { sv(idx, 1.0) }
            if let idx = stampBP { sv(idx, 1.0) }
            if let idx = stampNB { sv(idx, -1.0) }
            if let idx = stampBN { sv(idx, -1.0) }
            stamper.stampRHS(bIdx, scaledVoltage)
        } else {
            stamper.stampVoltageSource(posNode: posNode, negNode: negNode, branch: branch, voltage: scaledVoltage)
        }
    }
}

extension BoundVoltageSource: TransientPhysicalEquationDecomposing, TransientPhysicalEquationEnclosureDecomposing {
    public var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
    public func validateTransientPhysicalEquationDecomposition() throws {
        guard branchIdx != nil else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch",
                message: "Original transient source decomposition requires a bound branch")
        }
    }
    private func accumulateStaticSourceResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        guard let branchIdx else { throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "branch", message: "Direct transient residual requires a bound branch") }
        let current = try state.checkedBoundValue(at: branchIdx, for: .branchCurrent(branch))
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        let residual = try sourceEquation(state: state, voltage: waveform.value(at: time))
        try PhysicalResidualState.validate(current, residual, time)
        if let index = posIdx { add(index, current) }; if let index = negIdx { add(index, -current) }
        add(branchIdx, residual)
    }
    public func accumulateTransientStaticResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        try accumulateStaticSourceResidual(state: state, time: time, add: add)
    }
    public func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
        // Ideal source Q is identically zero; F uses the actual transient excitation.
        try accumulateTransientPhysicalResidual(state: state, integration: integration) { add($0, .staticResidual, $1) }
    }
    public func accumulateTransientStaticResidualEnclosure(state: SolutionState, time: Double,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        try accumulateResidualEnclosure(state: state, voltage: PhysicalResidualState.scalar(waveform.value(at: time)), add: add)
    }
    public func accumulateTransientPhysicalEquationEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws {
        try accumulateTransientStaticResidualEnclosure(state: state, time: integration.currentTime) {
            add($0, .staticResidual, $1, $2)
        }
    }
}

extension BoundVoltageSource: IndependentVoltageSourceFactProviding, ContinuousEquationLinearLawProviding {
    /// Opt-in external-coordinate path; the original DC/Waveform configuration is unchanged.
    package func makePrescribedVoltageLaw(zeroVoltage: Double, oneVoltage: Double,
        timeOrigin: Double, timeScale: Double, variableMap: [MNAVariable: Int], checkpoint: () throws -> Void)
        throws(BoundPrescribedVoltageFailure) -> BoundPrescribedVoltageLaw {
        try BoundPrescribedVoltageLaw.prepare(source: self, zeroVoltage: zeroVoltage, oneVoltage: oneVoltage,
            timeOrigin: timeOrigin, timeScale: timeScale, variableMap: variableMap, checkpoint: checkpoint)
    }
    internal func accumulatePrescribedResidual(state: SolutionState, voltage: Double,
        checkpoint: () throws -> Void, add: (Int, Double) throws -> Void) throws {
        try checkpoint()
        let values = try pointResidualValues(state: state, voltage: voltage)
        try checkpoint()
        if let row = posIdx { try add(row, values.current) }
        try checkpoint()
        if let row = negIdx { try add(row, -values.current) }
        try checkpoint()
        try add(values.branchRow, values.residual)
    }
    internal func accumulatePrescribedResidualEnclosure(state: SolutionState, voltage: CompensatedEnclosure,
        checkpoint: () throws -> Void, add: (Int, CompensatedValue, Double) throws -> Void) throws {
        // Admit all endpoint/branch candidates, including omitted ground contributions.
        for _ in 0..<3 { try checkpoint() }
        try checkpoint()
        try accumulateResidualEnclosure(state: state, voltage: voltage) { row, center, radius in
            try checkpoint()
            try add(row, center, radius)
        }
    }
    package func independentVoltageSourceFact() throws -> IndependentVoltageSourceFact {
        try .init(instance: instance, positiveNode: posNode, negativeNode: negNode, positiveRow: posIdx,
            negativeRow: negIdx, branch: branch, branchRow: branchIdx, dcVoltage: dcVoltage, waveform: waveform)
    }
    package func visitContinuousEquationLinearLaw(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationLinearTerm) throws -> Void) throws {
        try checkpoint()
        let fact = try independentVoltageSourceFact()
        try visitContinuousEquationLinearTerm(plane: .staticResidual,
            equation: .nodeVoltage(posNode), row: fact.positiveRow,
            coordinate: .branchCurrent(branch), column: fact.branchRow,
            coefficient: 1, device: instance.name, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationLinearTerm(plane: .staticResidual,
            equation: .branchCurrent(branch), row: fact.branchRow,
            coordinate: .nodeVoltage(posNode), column: fact.positiveRow,
            coefficient: 1, device: instance.name, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationLinearTerm(plane: .staticResidual,
            equation: .nodeVoltage(negNode), row: fact.negativeRow,
            coordinate: .branchCurrent(branch), column: fact.branchRow,
            coefficient: -1, device: instance.name, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationLinearTerm(plane: .staticResidual,
            equation: .branchCurrent(branch), row: fact.branchRow,
            coordinate: .nodeVoltage(negNode), column: fact.negativeRow,
            coefficient: -1, device: instance.name, checkpoint: checkpoint, visit: visit)
    }
    package func visitContinuousEquationStructure(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void
    ) throws {
        try checkpoint()
        let fact = try independentVoltageSourceFact()
        try visitContinuousEquationNode(posNode, index: posIdx, device: instance.name, access: .readCoordinate, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(negNode, index: negIdx, device: instance.name, access: .readCoordinate, checkpoint: checkpoint, visit: visit)
        try checkpoint()
        try visit(.readCoordinate, .branchCurrent(fact.branch), fact.branchRow)
        try visitContinuousEquationNode(posNode, index: posIdx, device: instance.name, access: .writeStaticResidual, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(negNode, index: negIdx, device: instance.name, access: .writeStaticResidual, checkpoint: checkpoint, visit: visit)
        try checkpoint()
        try visit(.writeStaticResidual, .branchCurrent(fact.branch), fact.branchRow)
    }
}
