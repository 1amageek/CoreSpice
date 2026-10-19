import Testing
@testable import CoreSpiceCompile

@Suite("Complete complex sparse LU")
struct TrueSparseComplexTests {
    @Test(arguments: [499, 500, 501], [false, true])
    func updatedSchurPivotAcrossFormerCrossover(dimension: Int, ordering: Bool) throws {
        var entries = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (2, 0), (2, 2)]
        for row in 3..<dimension { entries.append((row, row)) }
        let structure = try SparseStructure.fromTriplets(dimension: dimension, entries: entries)
        var matrix = ComplexSparseMatrix(structure: structure)
        for entry in entries {
            matrix.addValue(row: entry.0, col: entry.1, value: .one)
        }
        let expected = (0..<dimension).map { ComplexPair(real: Double($0 % 5) - 2, imag: Double($0 % 3) - 1) }
        let rhs = try matrix.multiply(vector: expected)
        var solver = ComplexSparseLUSolver(useAMDOrdering: ordering)
        try solver.factorize(matrix: matrix)
        let actual = try solver.solve(rhs: rhs)
        expectSolution(actual, expected: expected)
        expectSolution(try matrix.multiply(vector: actual), expected: rhs)
        var result = Array(repeating: ComplexPair.zero, count: dimension)
        try solver.solve(rhs: rhs, into: &result)
        expectSolution(result, expected: expected)
    }

    @Test(arguments: [false, true])
    func nonsymmetricComplexFillAndRepeatedPivots(ordering: Bool) throws {
        let first: [[ComplexPair]] = [
            [z(0.001, 0.002), z(2, 1), .zero, z(3, -1), .zero],
            [z(5, -2), z(1, 1), z(4, -1), .zero, .zero],
            [.zero, z(6, 2), z(1, -1), z(2, 1), .zero],
            [z(7, 1), .zero, .zero, z(1, 1), z(3, -2)],
            [.zero, z(2, -1), z(5, 1), .zero, z(4, 1)],
        ]
        var second = first
        second[0][0] = z(20, 1)
        second[1][0] = z(0.02, -0.01)
        second[2][1] = z(0.01, 0.02)
        second[3][0] = z(0.03, 0.01)
        let expected = [z(1, -1), z(-2, 0.5), z(3, 2), z(-1, 3), z(0.25, -0.75)]
        var solver = ComplexSparseLUSolver(useAMDOrdering: ordering)
        for dense in [first, second, first] {
            let matrix = try sparseMatrix(dense)
            let rhs = try matrix.multiply(vector: expected)
            try solver.factorize(matrix: matrix)
            let actual = try solver.solve(rhs: rhs)
            expectSolution(actual, expected: expected)
            expectSolution(actual, expected: try denseReference(dense, rhs: rhs))
            expectSolution(try matrix.multiply(vector: actual), expected: rhs)
        }
        solver.useAMDOrdering.toggle()
        let matrix = try sparseMatrix(first)
        try solver.factorize(matrix: matrix)
        expectSolution(try solver.solve(rhs: matrix.multiply(vector: expected)), expected: expected)
    }

    @Test(arguments: [1e-200, 1e200])
    func finiteScaleDoesNotBecomeSingularity(scale: Double) throws {
        let dense = [
            [z(2 * scale, scale), z(scale, -scale)],
            [z(-scale, scale), z(3 * scale, -scale)],
        ]
        let matrix = try sparseMatrix(dense)
        let expected = [z(1, 0.5), z(-0.5, 1)]
        var solver = ComplexSparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: matrix)
        expectSolution(try solver.solve(rhs: matrix.multiply(vector: expected)), expected: expected)
    }

    @Test func magnitudeAndDivisionPreserveRepresentableExtremes() {
        for scale in [Double.leastNonzeroMagnitude, 1e-200, 1e200, Double.greatestFiniteMagnitude] {
            let value = z(scale, scale)
            let quotient = value / value
            #expect(quotient.real == 1)
            #expect(quotient.imag == 0)
        }
        #expect(z(1e200, 1e200).magnitude.isFinite)
        #expect(z(1e-200, 1e-200).magnitude > 1e-200)
        #expect(z(Double.leastNonzeroMagnitude, 0).magnitude == Double.leastNonzeroMagnitude)
        #expect(z(Double.greatestFiniteMagnitude, 0).magnitude == Double.greatestFiniteMagnitude)
        let unequal = z(1e308, 1e-308) / z(1, 0)
        #expect(unequal.real == 1e308)
        #expect(unequal.imag == 1e-308)
        let mixed = z(1e308, 0) / z(2, Double.leastNonzeroMagnitude)
        #expect(mixed.real == 5e307)
        #expect(mixed.imag < 0)
        #expect(mixed.imag.isFinite)
        let phase = z(1e200, 1e200) / z(1e200, -1e200)
        #expect(abs(phase.real) < 1e-15)
        #expect(abs(phase.imag - 1) < 1e-15)
    }

    @Test(arguments: [-3.0, 3.0], [-4.0, 4.0])
    func scaledDivisionPreservesComponentSigns(real: Double, imaginary: Double) {
        let value = z(real, imaginary)
        let identity = value / .one
        #expect(identity == value)
        let rotated = value / z(0, 1)
        #expect(rotated.real == imaginary)
        #expect(rotated.imag == -real)
        let conjugateRatio = value / value.conjugate
        #expect(abs(conjugateRatio.real - (real * real - imaginary * imaginary) / 25) < 1e-15)
        #expect(abs(conjugateRatio.imag - 2 * real * imaginary / 25) < 1e-15)
    }

    @Test func failedFactorizationRefusesStaleFactorsAndRecovers() throws {
        var solver = ComplexSparseLUSolver()
        let valid = try sparseMatrix([[z(2, 1), .zero], [.zero, z(3, -1)]])
        try solver.factorize(matrix: valid)
        let invalidMatrices = [
            try sparseMatrix([[.zero, .zero], [.zero, z(3, -1)]]),
            try sparseMatrix([[z(.infinity, 0), .zero], [.zero, .one]]),
            try sparseMatrix([[z(1, .nan), .zero], [.zero, .one]]),
        ]
        for (index, invalid) in invalidMatrices.enumerated() {
            if index == 0 {
                #expect(throws: CompileError.singularMatrix) { try solver.factorize(matrix: invalid) }
            } else {
                #expect(throws: SparseSolverError.nonFiniteMatrixValue(index: 0)) {
                    try solver.factorize(matrix: invalid)
                }
            }
            #expect(throws: CompileError.singularMatrix) { _ = try solver.solve(rhs: [.one, .one]) }
            var output = [ComplexPair.zero, .zero]
            #expect(throws: CompileError.singularMatrix) {
                try solver.solve(rhs: [.one, .one], into: &output)
            }
            try solver.factorize(matrix: valid)
            expectSolution(try solver.solve(rhs: valid.multiply(vector: [.one, .one])), expected: [.one, .one])
        }
    }

    @Test func nonfiniteRightHandSideAndArithmeticAreRejected() throws {
        var solver = ComplexSparseLUSolver()
        try solver.factorize(matrix: sparseMatrix([[.one]]))
        for rhs in [z(.nan, 0), z(0, .infinity)] {
            #expect(throws: SparseSolverError.nonFiniteRHSValue(index: 0)) {
                _ = try solver.solve(rhs: [rhs])
            }
            var result = [ComplexPair.zero]
            #expect(throws: SparseSolverError.nonFiniteRHSValue(index: 0)) {
                try solver.solve(rhs: [rhs], into: &result)
            }
        }
        try solver.factorize(matrix: sparseMatrix([[z(Double.leastNonzeroMagnitude, 0)]]))
        #expect(throws: SparseSolverError.nonFiniteArithmetic) {
            _ = try solver.solve(rhs: [z(Double.greatestFiniteMagnitude, 0)])
        }
        #expect(throws: SparseSolverError.nonFiniteArithmetic) {
            try solver.factorize(matrix: sparseMatrix([
                [z(1e308, 0), z(1e308, 0)],
                [z(-1e308, 0), z(1e308, 0)],
            ]))
        }
        #expect(throws: CompileError.singularMatrix) { _ = try solver.solve(rhs: [.one, .one]) }
    }

    private func z(_ real: Double, _ imag: Double) -> ComplexPair {
        ComplexPair(real: real, imag: imag)
    }

    private func sparseMatrix(_ dense: [[ComplexPair]]) throws -> ComplexSparseMatrix {
        var entries: [(Int, Int)] = []
        for row in dense.indices {
            for column in dense.indices where row == column || dense[row][column] != .zero {
                entries.append((row, column))
            }
        }
        let structure = try SparseStructure.fromTriplets(dimension: dense.count, entries: entries)
        var matrix = ComplexSparseMatrix(structure: structure)
        for (row, column) in entries {
            matrix.addValue(row: row, col: column, value: dense[row][column])
        }
        return matrix
    }

    private func expectSolution(_ actual: [ComplexPair], expected: [ComplexPair]) {
        #expect(actual.count == expected.count)
        for index in actual.indices {
            let error = (actual[index] - expected[index]).magnitude
            #expect(error <= 1e-10 * max(1, expected[index].magnitude), "Mismatch at index \(index)")
        }
    }

    private func denseReference(_ matrix: [[ComplexPair]], rhs: [ComplexPair]) throws -> [ComplexPair] {
        var rows = matrix
        var result = rhs
        for column in rows.indices {
            var pivot = column
            for row in (column + 1)..<rows.count {
                if rows[row][column].magnitude > rows[pivot][column].magnitude { pivot = row }
            }
            guard rows[pivot][column] != .zero else { throw CompileError.singularMatrix }
            rows.swapAt(column, pivot)
            result.swapAt(column, pivot)
            for row in (column + 1)..<rows.count {
                let multiplier = rows[row][column] / rows[column][column]
                for entry in column..<rows.count {
                    rows[row][entry] = rows[row][entry] - multiplier * rows[column][entry]
                }
                result[row] = result[row] - multiplier * result[column]
            }
        }
        for row in rows.indices.reversed() {
            for column in (row + 1)..<rows.count {
                result[row] = result[row] - rows[row][column] * result[column]
            }
            result[row] = result[row] / rows[row][row]
        }
        return result
    }
}
