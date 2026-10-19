import Foundation
import CoreSpiceIR

/// A resistor bound to specific circuit nodes.
///
/// Stamps admitted temperature-adjusted DC and independent AC conductances.
/// Thermal and flicker spectra consume the same prepared static law.
public struct BoundResistor: BoundDevice, TransientPhysicalResidualContributing, TransientPhysicalResidualEnclosureContributing, DCPhysicalResidualContributing, DCPhysicalResidualEnclosureContributing, NoisyDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let parameters: StaticResistorParameters

    /// Pre-resolved node indices (nil for ground).
    private let posIdx: Int?
    private let negIdx: Int?

    /// Pre-resolved CSR value indices for O(1) stamping.
    private let stampPP: Int?
    private let stampNN: Int?
    private let stampPN: Int?
    private let stampNP: Int?

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        parameters: StaticResistorParameters,
        posIdx: Int? = nil,
        negIdx: Int? = nil,
        stampPP: Int? = nil,
        stampNN: Int? = nil,
        stampPN: Int? = nil,
        stampNP: Int? = nil
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.parameters = parameters
        self.posIdx = posIdx
        self.negIdx = negIdx
        self.stampPP = stampPP
        self.stampNN = stampNN
        self.stampPN = stampPN
        self.stampNP = stampNP
    }

    public func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        if let index = posIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(posNode)) }
        if let index = negIdx { _ = try state.checkedBoundValue(at: index, for: .nodeVoltage(negNode)) }
        let value = try current(state: state)
        if let index = posIdx { add(index, value) }
        if let index = negIdx { add(index, -value) }
    }

    public func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
        try accumulatePhysicalResidual(state: state, add: add)
    }

    public func accumulateTransientPhysicalResidualEnclosure(
        state: SolutionState, integration: IntegrationState, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        try accumulatePhysicalResidualEnclosure(state: state, sourceScale: 1, add: add)
    }

    public func accumulatePhysicalResidualEnclosure(
        state: SolutionState, sourceScale: Double, add: (Int, CompensatedValue, Double) -> Void
    ) throws {
        guard sourceScale.isFinite, (0...1).contains(sourceScale) else {
            throw invalid("sourceScale", "DC source scale must be finite and within zero and one")
        }
        let voltage = try PhysicalResidualState.voltageDifference(state, positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx)
        let current = try voltage.multiplied(by: PhysicalResidualState.scalar(parameters.conductance))
        if let index = posIdx { add(index, current.center, current.radius) }
        if let index = negIdx { add(index, current.center.negated(), current.radius) }
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        _ = try current(state: state)
        let g = parameters.conductance
        if let sv = stamper.stampValue, stampPP != nil || stampNN != nil {
            if let idx = stampPP { sv(idx, g) }
            if let idx = stampNN { sv(idx, g) }
            if let idx = stampPN { sv(idx, -g) }
            if let idx = stampNP { sv(idx, -g) }
        } else {
            stamper.stampConductance(node1: posNode, node2: negNode, conductance: g)
        }
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        _ = try current(state: state)
        let conductance = parameters.acConductance
        stamper.stampAdmittance(node1: posNode, node2: negNode, real: conductance, imag: 0.0)
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        // Resistor is memoryless; same as DC.
        try stampDC(into: &stamper, state: state)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges in one iteration.
        .converged
    }

    // MARK: - NoisyDevice

    /// Boltzmann constant (J/K).
    private static let kB: Double = 1.380649e-23

    public func noiseContributions(state: SolutionState, frequency: Double) throws -> [NoiseSource] {
        guard parameters.noisy else { return [] }
        guard frequency.isFinite, frequency > 0 else {
            throw invalid("frequency", "Noise frequency must be finite and positive")
        }
        let thermal = 4 * Self.kB * parameters.noiseTemperatureKelvin * parameters.conductance
        var result = [NoiseSource(name: "\(instance.name)_thermal", positiveNode: posNode,
            negativeNode: negNode, currentSpectralDensity: thermal)]
        if parameters.flickerCoefficient > 0 {
            let unitCurrent = abs(try current(state: state) / parameters.multiplier)
            let numerator = parameters.multiplier * parameters.flickerCoefficient
                * pow(unitCurrent, parameters.flickerCurrentExponent)
            let denominator = parameters.effectiveNoiseArea * pow(frequency, parameters.flickerFrequencyExponent)
            let flicker = numerator / denominator
            guard numerator.isFinite, denominator.isFinite, denominator > 0,
                  flicker.isFinite, flicker >= 0 else {
                throw invalid("flickerNoise", "Flicker spectrum is outside the finite nonnegative domain")
            }
            result.append(NoiseSource(name: "\(instance.name)_1overf", positiveNode: posNode,
                negativeNode: negNode, currentSpectralDensity: flicker))
        }
        return result
    }

    private func current(state: SolutionState) throws -> Double {
        if state.variableLowComponents != nil {
            let voltage = try PhysicalResidualState.voltageDifference(state, positive: posNode, negative: negNode,
                positiveIndex: posIdx, negativeIndex: negIdx)
            let current = try voltage.multiplied(by: PhysicalResidualState.scalar(parameters.conductance)).center
            return current.high + current.low
        }
        let voltage = try state.checkedVoltage(at: posNode) - state.checkedVoltage(at: negNode)
        let current = voltage * parameters.conductance
        guard voltage.isFinite, current.isFinite else {
            throw invalid("current", "Resistor terminal voltage or current overflow")
        }
        return current
    }

    private func invalid(_ parameter: String, _ message: String) -> DeviceBindingError {
        .invalidParameterValue(device: instance.name, parameter: parameter, message: message)
    }
}

extension BoundResistor: TransientPhysicalEquationDecomposing, TransientPhysicalEquationEnclosureDecomposing {
    public var transientPhysicalEquationForm: TransientPhysicalEquationForm { .chargeDifference }
    public func validateTransientPhysicalEquationDecomposition() throws {
        try PhysicalResidualState.validate(parameters.conductance)
    }
    public func accumulateTransientStaticResidual(state: SolutionState, time: Double,
        add: (Int, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        try accumulatePhysicalResidual(state: state, add: add)
    }
    public func accumulateTransientPhysicalEquation(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void) throws {
        // The admitted resistor has identically zero Q.
        try accumulateTransientStaticResidual(state: state, time: integration.currentTime) { add($0, .staticResidual, $1) }
    }
    public func accumulateTransientStaticResidualEnclosure(state: SolutionState, time: Double,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        try PhysicalResidualState.validate(time)
        try accumulatePhysicalResidualEnclosure(state: state, sourceScale: 1, add: add)
    }
    public func accumulateTransientPhysicalEquationEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void) throws {
        try accumulateTransientStaticResidualEnclosure(state: state, time: integration.currentTime) {
            add($0, .staticResidual, $1, $2)
        }
    }
}

extension BoundResistor: ContinuousEquationLinearLawProviding {
    package func visitContinuousEquationLinearLaw(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationLinearTerm) throws -> Void) throws {
        try visitContinuousEquationTwoTerminalLaw(positive: posNode, negative: negNode,
            positiveIndex: posIdx, negativeIndex: negIdx, plane: .staticResidual,
            coefficient: parameters.conductance, device: instance.name, checkpoint: checkpoint, visit: visit)
    }
    package func visitContinuousEquationStructure(checkpoint: () throws -> Void,
        _ visit: (ContinuousEquationAccess, MNAVariable, Int) throws -> Void
    ) throws {
        try visitContinuousEquationNode(posNode, index: posIdx, device: instance.name, access: .readCoordinate, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(negNode, index: negIdx, device: instance.name, access: .readCoordinate, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(posNode, index: posIdx, device: instance.name, access: .writeStaticResidual, checkpoint: checkpoint, visit: visit)
        try visitContinuousEquationNode(negNode, index: negIdx, device: instance.name, access: .writeStaticResidual, checkpoint: checkpoint, visit: visit)
    }
}
