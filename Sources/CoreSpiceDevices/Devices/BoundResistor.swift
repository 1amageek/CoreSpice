import CoreSpiceIR

/// A resistor bound to specific circuit nodes.
///
/// Stamps conductance `g = 1/R` between its two terminals.
/// The resistor is frequency-independent and always linear,
/// so all analysis types use the same conductance stamp.
public struct BoundResistor: BoundDevice, NoisyDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let resistance: Double

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
        resistance: Double,
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
        self.resistance = resistance
        self.posIdx = posIdx
        self.negIdx = negIdx
        self.stampPP = stampPP
        self.stampNN = stampNN
        self.stampPN = stampPN
        self.stampNP = stampNP
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let g = 1.0 / resistance
        if let sv = stamper.stampValue, stampPP != nil || stampNN != nil {
            if let idx = stampPP { sv(idx, g) }
            if let idx = stampNN { sv(idx, g) }
            if let idx = stampPN { sv(idx, -g) }
            if let idx = stampNP { sv(idx, -g) }
        } else {
            stamper.stampConductance(node1: posNode, node2: negNode, conductance: g)
        }
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        let conductance = 1.0 / resistance
        stamper.stampAdmittance(node1: posNode, node2: negNode, real: conductance, imag: 0.0)
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {
        // Resistor is memoryless; same as DC.
        stampDC(into: &stamper, state: state)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // Linear device always converges in one iteration.
        .converged
    }

    // MARK: - NoisyDevice

    /// Boltzmann constant (J/K).
    private static let kB: Double = 1.380649e-23

    /// Default temperature (300K ≈ 27°C).
    private static let temperature: Double = 300.0

    public func noiseContributions(state: SolutionState, frequency: Double) -> [NoiseSource] {
        // Thermal noise: spectral density = 4kT/R [A²/Hz]
        let spectralDensity = 4.0 * Self.kB * Self.temperature / resistance
        return [
            NoiseSource(
                name: "\(instance.name)_thermal",
                positiveNode: posNode,
                negativeNode: negNode,
                currentSpectralDensity: spectralDensity
            )
        ]
    }
}
