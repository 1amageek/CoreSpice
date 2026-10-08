import Foundation
import CoreSpiceIR

/// A resistor bound to specific circuit nodes.
///
/// Stamps admitted temperature-adjusted DC and independent AC conductances.
/// Thermal and flicker spectra consume the same prepared static law.
public struct BoundResistor: BoundDevice, NoisyDevice, Sendable {

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
