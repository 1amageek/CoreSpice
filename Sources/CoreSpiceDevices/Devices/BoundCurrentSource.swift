import CoreSpiceIR
import Foundation

/// A current source bound to specific circuit nodes.
///
/// SPICE convention: positive current flows from the positive node, through the
/// source, to the negative node, so current is drawn from the positive node and
/// injected into the negative node.
/// No branch variable is needed; only the RHS is stamped.
public struct BoundCurrentSource: BoundDevice, TransientPhysicalResidualContributing, TransientPhysicalResidualEnclosureContributing, DCPhysicalResidualContributing, DCPhysicalResidualEnclosureContributing, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let dcCurrent: Double
    private let acMagnitude: Double
    private let acPhaseDegrees: Double
    private let waveform: Waveform

    /// Pre-resolved matrix index for the positive node (nil for ground).
    private let posIdx: Int?
    /// Pre-resolved matrix index for the negative node (nil for ground).
    private let negIdx: Int?

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        dcCurrent: Double,
        acMagnitude: Double,
        acPhaseDegrees: Double = 0,
        waveform: Waveform,
        posIdx: Int?,
        negIdx: Int?
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.dcCurrent = dcCurrent
        self.acMagnitude = acMagnitude
        self.acPhaseDegrees = acPhaseDegrees.truncatingRemainder(dividingBy: 360)
        self.waveform = waveform
        self.posIdx = posIdx
        self.negIdx = negIdx
    }

    public func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        let positive = try state.checkedVoltage(at: posNode)
        let negative = try state.checkedVoltage(at: negNode)
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        guard positive.isFinite, negative.isFinite, dcCurrent.isFinite else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name,
                parameter: "dcResidual", message: "Physical DC source current is nonfinite")
        }
        if let index = posIdx { add(index, dcCurrent) }
        if let index = negIdx { add(index, -dcCurrent) }
    }

    public func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
        try accumulateStaticSourceResidual(state: state, time: integration.currentTime, add: add)
    }

    public func accumulateTransientPhysicalResidualEnclosure(
        state: SolutionState, integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        try PhysicalResidualState.validate(integration.currentTime)
        try accumulateResidualEnclosure(state: state,
            current: PhysicalResidualState.scalar(waveform.value(at: integration.currentTime)), add: add)
    }

    public func accumulatePhysicalResidualEnclosure(
        state: SolutionState, sourceScale: Double, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        guard sourceScale.isFinite, (0...1).contains(sourceScale) else {
            throw DeviceBindingError.invalidParameterValue(device: instance.name, parameter: "sourceScale",
                message: "DC source scale must be finite and within zero and one")
        }
        let current = try PhysicalResidualState.scalar(dcCurrent)
            .multiplied(by: PhysicalResidualState.scalar(sourceScale))
        try accumulateResidualEnclosure(state: state, current: current, add: add)
    }

    private func accumulateResidualEnclosure(
        state: SolutionState, current: CompensatedEnclosure,
        add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        _ = try PhysicalResidualState.voltage(state, node: posNode, index: posIdx)
        _ = try PhysicalResidualState.voltage(state, node: negNode, index: negIdx)
        if let index = posIdx { add(index, current.center, current.radius) }
        if let index = negIdx { add(index, current.center.negated(), current.radius) }
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // SPICE convention: positive current flows from the positive node,
        // through the source, to the negative node. Current is drawn from the
        // positive node and injected into the negative node.
        if let i = posIdx {
            stamper.stampRHS(i, -dcCurrent)
        }
        if let j = negIdx {
            stamper.stampRHS(j, dcCurrent)
        }
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Preserve the same SPICE terminal orientation as DC and transient.
        if let posIdx { stamper.stampRHS(posIdx, -acMagnitude * cos(acPhaseDegrees * .pi / 180), -acMagnitude * sin(acPhaseDegrees * .pi / 180)) }
        if let negIdx { stamper.stampRHS(negIdx, acMagnitude * cos(acPhaseDegrees * .pi / 180), acMagnitude * sin(acPhaseDegrees * .pi / 180)) }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        let current = waveform.value(at: integration.currentTime)
        if let i = posIdx {
            stamper.stampRHS(i, -current)
        }
        if let j = negIdx {
            stamper.stampRHS(j, current)
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
    ///   - factor: Scaling factor (0.0 to 1.0) applied to the source current.
    public func stampDCScaled(into stamper: inout MatrixStamper, state: SolutionState, factor: Double) {
        let scaledCurrent = dcCurrent * factor
        if let i = posIdx {
            stamper.stampRHS(i, -scaledCurrent)
        }
        if let j = negIdx {
            stamper.stampRHS(j, scaledCurrent)
        }
    }
}

extension BoundCurrentSource: TransientPhysicalEquationDecomposing, TransientPhysicalEquationEnclosureDecomposing {
    public var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
    public func validateTransientPhysicalEquationDecomposition() throws {
        try PhysicalResidualState.validate(dcCurrent)
    }
    private func accumulateStaticSourceResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        try PhysicalResidualState.validate(try state.checkedVoltage(at: posNode), try state.checkedVoltage(at: negNode))
        let current = waveform.value(at: time)
        try PhysicalResidualState.validate(current, time)
        if let index = posIdx { add(index, current) }; if let index = negIdx { add(index, -current) }
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
        try accumulateResidualEnclosure(state: state, current: PhysicalResidualState.scalar(waveform.value(at: time)), add: add)
    }
    public func accumulateTransientPhysicalEquationEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws {
        try accumulateTransientStaticResidualEnclosure(state: state, time: integration.currentTime) {
            add($0, .staticResidual, $1, $2)
        }
    }
}
