/// Failures do not publish a partial successful spectrum.
enum GeneralizedSchurError: Error, Equatable {
    case invalidDimension(Int)
    case matrixSizeMismatch(expected: Int, matrixA: Int, matrixB: Int)
    case nonFiniteMatrixValue(matrix: String, index: Int)
    case nonFiniteArithmetic
    case scalingUnderflow
    case indeterminateEigenvalue(index: Int)
    case nonConvergence(first: Int, last: Int, sweeps: Int)
    case shiftFailure
    case unresolvedEigenvalueClassification(index: Int)
    case invalidSchurQuality
    case finiteProjectionOverflow(index: Int)
}
