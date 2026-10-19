/// Sparse arithmetic and admission failures, distinct from mathematical singularity.
public enum SparseSolverError: Error, Sendable, Equatable {
    case capacityOverflow
    case workOverflow
    case executionControlUnsupported
    case nonFiniteMatrixValue(index: Int)
    case nonFiniteRHSValue(index: Int)
    case nonFiniteArithmetic
}
