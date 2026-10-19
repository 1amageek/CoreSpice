import Testing
@testable import CoreSpiceCompile

@Suite("Accurate sparse residual", .timeLimit(.minutes(1)))
struct SparseResidualTests {
    @Test func exactBinaryProductCancellationRequiresProductError() throws {
        let g = 1e16
        let d = Double.ulpOfOne
        let coefficients = [g, -g, 1.0]
        let vector = [1 + d, 1, -g * d]
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(
            dimension: 3, entries: [(0, 0), (0, 1), (0, 2)]))
        for column in coefficients.indices {
            matrix.addValue(row: 0, col: column, value: coefficients[column])
        }
        // G*d is an exact binary exponent shift, so the exact row is G+G*d-G-G*d = 0.
        let naive = try matrix.checkedMultiply(vector: vector)
        var kahan = 0.0, correction = 0.0
        for column in coefficients.indices {
            let term = coefficients[column] * vector[column] - correction
            let next = kahan + term
            correction = (next - kahan) - term
            kahan = next
        }
        #expect(naive[0] != 0)
        #expect(kahan != 0)
        var residual = [7.0, 7.0, 7.0]
        try matrix.checkedResidual(vector: vector, rhs: [0, 0, 0], into: &residual)
        #expect(residual == [0, 0, 0])
    }

    @Test(arguments: [1.0, -1.0])
    func rhsCancellationParticipatesInCompensation(sign: Double) throws {
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(
            dimension: 2, entries: [(0, 0), (0, 1)]))
        matrix.addValue(row: 0, col: 0, value: sign * 1e16)
        matrix.addValue(row: 0, col: 1, value: sign)
        var residual = [0.0, 0.0]
        try matrix.checkedResidual(vector: [1, 1], rhs: [sign * 1e16, 3], into: &residual)
        #expect(residual == [sign, -3])
    }

    @Test func emptyMatrixHasEmptyResidual() throws {
        let matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: 0, entries: []))
        var residual: [Double] = []
        try matrix.checkedResidual(vector: [], rhs: [], into: &residual)
        #expect(residual.isEmpty)
    }

    @Test func rejectsAllThreeShapeMismatchesBeforeWriting() throws {
        let matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: 2, entries: []))
        var short = [7.0]
        #expect(throws: SparseMatrixError.resultLengthMismatch(expected: 2, actual: 1)) {
            try matrix.checkedResidual(vector: [1, 1], rhs: [0, 0], into: &short)
        }
        #expect(short == [7])
        var residual = [7.0, 7.0]
        #expect(throws: SparseMatrixError.vectorLengthMismatch(expected: 2, actual: 1)) {
            try matrix.checkedResidual(vector: [1], rhs: [0, 0], into: &residual)
        }
        #expect(throws: SparseMatrixError.rhsLengthMismatch(expected: 2, actual: 1)) {
            try matrix.checkedResidual(vector: [1, 1], rhs: [0], into: &residual)
        }
        #expect(residual == [7, 7])
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func rejectsNonfiniteOperands(value: Double) throws {
        let structure = try SparseStructure.fromTriplets(dimension: 1, entries: [(0, 0)])
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 1)
        var residual = [7.0]
        #expect(throws: SparseMatrixError.nonFiniteVectorValue(index: 0)) {
            try matrix.checkedResidual(vector: [value], rhs: [0], into: &residual)
        }
        #expect(throws: SparseMatrixError.nonFiniteRHSValue(index: 0)) {
            try matrix.checkedResidual(vector: [1], rhs: [value], into: &residual)
        }
        matrix.clear()
        matrix.addValue(row: 0, col: 0, value: value)
        #expect(throws: SparseMatrixError.nonFiniteMatrixValue(row: 0, column: 0)) {
            try matrix.checkedResidual(vector: [1], rhs: [0], into: &residual)
        }
    }

    @Test func productAndAccumulatorOverflowFailExplicitly() throws {
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(
            dimension: 2, entries: [(0, 0), (0, 1)]))
        matrix.addValue(row: 0, col: 0, value: Double.greatestFiniteMagnitude)
        var residual = [0.0, 0.0]
        #expect(throws: SparseMatrixError.residualOverflow(row: 0)) {
            try matrix.checkedResidual(vector: [2, 0], rhs: [0, 0], into: &residual)
        }
        matrix.addValue(row: 0, col: 1, value: Double.greatestFiniteMagnitude)
        #expect(throws: SparseMatrixError.residualOverflow(row: 0)) {
            try matrix.checkedResidual(vector: [1, 1], rhs: [0, 0], into: &residual)
        }
        #expect(throws: SparseMatrixError.residualOverflow(row: 0)) {
            try matrix.checkedResidual(vector: [-1, 0], rhs: [Double.greatestFiniteMagnitude, 0], into: &residual)
        }
    }
}
