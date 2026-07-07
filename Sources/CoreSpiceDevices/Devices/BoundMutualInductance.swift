import CoreSpiceIR

/// A mutual inductance coupling between two already-bound inductor branches.
public struct BoundMutualInductance: BoundDevice, Sendable {

    public let instance: Instance

    private let branchA: Branch
    private let branchB: Branch
    private let branchAIdx: Int?
    private let branchBIdx: Int?
    private let mutualInductance: Double

    init(
        instance: Instance,
        branchA: Branch,
        branchB: Branch,
        branchAIdx: Int?,
        branchBIdx: Int?,
        mutualInductance: Double
    ) {
        self.instance = instance
        self.branchA = branchA
        self.branchB = branchB
        self.branchAIdx = branchAIdx
        self.branchBIdx = branchBIdx
        self.mutualInductance = mutualInductance
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // Ideal mutual inductance has no additional DC constraint.
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        guard let idxA = branchAIdx ?? stamper.branchIndex(branchA),
              let idxB = branchBIdx ?? stamper.branchIndex(branchB) else {
            return
        }
        let imag = -omega * mutualInductance
        stamper.stampMatrix(idxA, idxB, 0.0, imag)
        stamper.stampMatrix(idxB, idxA, 0.0, imag)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        guard let idxA = branchAIdx ?? stamper.branchIndex(branchA),
              let idxB = branchBIdx ?? stamper.branchIndex(branchB) else {
            return
        }

        let req = mutualInductance * integration.coefficient
        stamper.stampMatrix(idxA, idxB, -req)
        stamper.stampMatrix(idxB, idxA, -req)

        let previousA = state.previousValue(at: idxA)
        let previousB = state.previousValue(at: idxB)
        stamper.stampRHS(idxA, -req * previousB)
        stamper.stampRHS(idxB, -req * previousA)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}
