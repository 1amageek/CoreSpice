import CoreSpiceCompile

/// Compatibility projection over the Pure Swift generalized Schur component.
struct GeneralizedEigenSolver {
    struct EigenResult {
        let eigenvalues: [ComplexPair]
        let homogeneousEigenvalues: [HomogeneousEigenvalue]
        let infiniteEigenvalueCount: Int
        let retainedStorage: (any Sendable)?
    }

    enum EigenSolverError: Error, Equatable {
        case indeterminateEigenvalue(index: Int)
        case emptyMatrix
        case dimensionTooLarge(Int)
        case matrixSizeMismatch(expected: Int, matrixA: Int, matrixB: Int)
        case nonFiniteMatrixValue(matrix: String, index: Int, value: Double)
    }

    /// All homogeneous entries are validated before the existing finite-only projection.
    static func solve(matrixA: [Double], matrixB: [Double], dimension: Int,
                      control: (any LinearSolverExecutionControlling)? = nil) throws -> EigenResult {
        try control?.checkpoint(workUnits: 0)
        guard dimension > 0 else { throw EigenSolverError.emptyMatrix }
        let (count, overflow) = dimension.multipliedReportingOverflow(by: dimension)
        guard !overflow else { throw EigenSolverError.dimensionTooLarge(dimension) }
        guard matrixA.count == count, matrixB.count == count else {
            throw EigenSolverError.matrixSizeMismatch(expected: count,
                matrixA: matrixA.count, matrixB: matrixB.count)
        }
        // This small lease survives the temporary Schur factors and owns both output arrays.
        let (outputBytes, outputOverflow) = dimension.multipliedReportingOverflow(by: 5 * MemoryLayout<Double>.stride)
        guard !outputOverflow else { throw EigenSolverError.dimensionTooLarge(dimension) }
        let storage = try control?.reserveStorage(byteCount: outputBytes)
        do {
            let decomposition = try GeneralizedSchur.decompose(matrixA: matrixA,
                matrixB: matrixB, dimension: dimension, control: control)
            let finite = try decomposition.finiteEigenvalues(control: control)
            return EigenResult(eigenvalues: finite, homogeneousEigenvalues: decomposition.eigenvalues,
                infiniteEigenvalueCount: dimension - finite.count, retainedStorage: storage)
        } catch GeneralizedSchurError.nonFiniteMatrixValue(let matrix, let index) {
            throw EigenSolverError.nonFiniteMatrixValue(matrix: matrix, index: index,
                value: matrix == "A" ? matrixA[index] : matrixB[index])
        } catch GeneralizedSchurError.indeterminateEigenvalue(let index) {
            throw EigenSolverError.indeterminateEigenvalue(index: index)
        }
    }
}
