import CoreSpiceIR

/// A voltage source bound to specific circuit nodes and a branch variable.
///
/// The voltage source imposes `V(pos) - V(neg) = V` and introduces
/// a branch current variable into the MNA system.
public struct BoundVoltageSource: BoundDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let dcVoltage: Double
    private let acMagnitude: Double
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
            real: acMagnitude, imag: 0.0
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

    public func breakpoints(in interval: ClosedRange<Double>) -> [Double] {
        waveform.breakpoints(in: interval)
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
