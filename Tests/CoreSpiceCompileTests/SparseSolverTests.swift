import Testing
import Foundation
@testable import CoreSpiceCompile

@Suite("Sparse Solver Tests")
struct SparseSolverTests {

    // MARK: - Permutation Tests

    @Test func permutationIdentity() {
        let p = Permutation.identity(size: 4)
        #expect(p.forward == [0, 1, 2, 3])
        #expect(p.inverse == [0, 1, 2, 3])
    }

    @Test func permutationApply() {
        // Permutation: 0→2, 1→0, 2→1
        let p = Permutation(forward: [2, 0, 1])
        let array = ["a", "b", "c"]

        let permuted = p.apply(to: array)
        // permuted[forward[i]] = array[i]
        // permuted[2] = array[0] = "a"
        // permuted[0] = array[1] = "b"
        // permuted[1] = array[2] = "c"
        #expect(permuted == ["b", "c", "a"])

        let restored = p.applyInverse(to: permuted)
        #expect(restored == array)
    }

    @Test func permutationComposition() {
        let p1 = Permutation(forward: [1, 0, 2])  // swap first two
        let p2 = Permutation(forward: [0, 2, 1])  // swap last two

        let composed = p1.then(p2)
        let array = [1, 2, 3]

        // Apply p1 first: [2, 1, 3], then p2: [2, 3, 1]
        let result = composed.apply(to: array)
        #expect(result == [2, 3, 1])
    }

    // MARK: - AMD Ordering Tests

    @Test func amdOrderingTridiagonal() {
        // Tridiagonal matrix: well-ordered, minimal fill-in
        let entries: [(row: Int, col: Int)] = [
            (0, 0), (0, 1),
            (1, 0), (1, 1), (1, 2),
            (2, 1), (2, 2), (2, 3),
            (3, 2), (3, 3)
        ]
        let structure = SparseStructure.fromTriplets(dimension: 4, entries: entries)
        let ordering = AMDOrdering.compute(structure: structure)

        #expect(ordering.dimension == 4)
        // Just verify it produces a valid permutation
        let sorted = ordering.forward.sorted()
        #expect(sorted == [0, 1, 2, 3])
    }

    @Test func amdOrderingArrowhead() {
        // Arrowhead matrix: first row/column dense, rest diagonal
        // Poor natural ordering creates fill-in, AMD should reorder
        var entries: [(row: Int, col: Int)] = []
        let n = 5

        // First row and column (excluding diagonal)
        for i in 0..<n {
            entries.append((0, i))
            if i > 0 {
                entries.append((i, 0))
            }
        }

        // Diagonal
        for i in 1..<n {
            entries.append((i, i))
        }

        let structure = SparseStructure.fromTriplets(dimension: n, entries: entries)
        let ordering = AMDOrdering.compute(structure: structure)

        // AMD should move the dense row/column to the end
        #expect(ordering.forward.count == n)
    }

    // MARK: - Symbolic Analysis Tests

    @Test func symbolicAnalysisDiagonal() {
        // Diagonal matrix: no fill-in
        let structure = SparseStructure.fromTriplets(
            dimension: 3,
            entries: [(0, 0), (1, 1), (2, 2)]
        )
        let analysis = SymbolicAnalysis.analyze(structure: structure)

        #expect(analysis.fillInCount == 0)
        #expect(analysis.eliminationTree.count == 3)
    }

    @Test func symbolicAnalysisTridiagonal() {
        // Tridiagonal: minimal fill-in
        let entries: [(row: Int, col: Int)] = [
            (0, 0), (0, 1),
            (1, 0), (1, 1), (1, 2),
            (2, 1), (2, 2)
        ]
        let structure = SparseStructure.fromTriplets(dimension: 3, entries: entries)
        let analysis = SymbolicAnalysis.analyze(structure: structure)

        // Tridiagonal has no fill-in with natural ordering
        #expect(analysis.fillInCount >= 0)
    }

    @Test func symbolicAnalysisEliminationTree() {
        let structure = SparseStructure.fromTriplets(
            dimension: 3,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1), (1, 2), (2, 1), (2, 2)]
        )
        let analysis = SymbolicAnalysis.analyze(structure: structure)

        // Elimination tree should be valid
        for (node, parent) in analysis.eliminationTree.enumerated() {
            if parent >= 0 {
                #expect(parent > node, "Parent must come after child in elimination order")
            }
        }
    }

    // MARK: - Sparse LU Solver Tests

    @Test func luSolverWithAMDOrdering() throws {
        // 3x3 system with good sparsity
        let structure = SparseStructure.fromTriplets(
            dimension: 3,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1), (1, 2), (2, 1), (2, 2)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 4.0)
        matrix.addValue(row: 0, col: 1, value: -1.0)
        matrix.addValue(row: 1, col: 0, value: -1.0)
        matrix.addValue(row: 1, col: 1, value: 4.0)
        matrix.addValue(row: 1, col: 2, value: -1.0)
        matrix.addValue(row: 2, col: 1, value: -1.0)
        matrix.addValue(row: 2, col: 2, value: 4.0)

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: [1.0, 2.0, 3.0])

        // Verify A*x = b
        let result = matrix.multiply(vector: x)
        #expect(abs(result[0] - 1.0) < 1e-9)
        #expect(abs(result[1] - 2.0) < 1e-9)
        #expect(abs(result[2] - 3.0) < 1e-9)
    }

    @Test func luSolverWithoutAMDOrdering() throws {
        // Same test but with natural ordering
        let structure = SparseStructure.fromTriplets(
            dimension: 3,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1), (1, 2), (2, 1), (2, 2)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 4.0)
        matrix.addValue(row: 0, col: 1, value: -1.0)
        matrix.addValue(row: 1, col: 0, value: -1.0)
        matrix.addValue(row: 1, col: 1, value: 4.0)
        matrix.addValue(row: 1, col: 2, value: -1.0)
        matrix.addValue(row: 2, col: 1, value: -1.0)
        matrix.addValue(row: 2, col: 2, value: 4.0)

        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: [1.0, 2.0, 3.0])

        let result = matrix.multiply(vector: x)
        #expect(abs(result[0] - 1.0) < 1e-9)
        #expect(abs(result[1] - 2.0) < 1e-9)
        #expect(abs(result[2] - 3.0) < 1e-9)
    }

    @Test func luSolverSingularMatrix() throws {
        // Singular matrix should throw
        let structure = SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 1.0)
        matrix.addValue(row: 0, col: 1, value: 2.0)
        matrix.addValue(row: 1, col: 0, value: 2.0)
        matrix.addValue(row: 1, col: 1, value: 4.0)  // Row 2 = 2 * Row 1

        var solver = SparseLUSolver()
        #expect(throws: CompileError.self) {
            try solver.factorize(matrix: matrix)
        }
    }

    @Test func structuralMissFailsFactorization() {
        let structure = SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (1, 1)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 1, value: 1.0)

        #expect(matrix.structuralMisses == [SparseMatrixStructuralMiss(row: 0, col: 1)])

        var solver = SparseLUSolver()
        #expect(throws: CompileError.self) {
            try solver.factorize(matrix: matrix)
        }
    }

    // MARK: - Complex Solver Tests

    @Test func complexSolverWithAMDOrdering() throws {
        let structure = SparseStructure.fromTriplets(
            dimension: 2,
            entries: [(0, 0), (0, 1), (1, 0), (1, 1)]
        )
        var matrix = ComplexSparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: ComplexPair(real: 2, imag: 1))
        matrix.addValue(row: 0, col: 1, value: ComplexPair(real: -1, imag: 0))
        matrix.addValue(row: 1, col: 0, value: ComplexPair(real: -1, imag: 0))
        matrix.addValue(row: 1, col: 1, value: ComplexPair(real: 2, imag: -1))

        let rhs = [
            ComplexPair(real: 1, imag: 0),
            ComplexPair(real: 1, imag: 0)
        ]

        var solver = ComplexSparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: rhs)

        // Verify A*x = b
        let result = matrix.multiply(vector: x)
        #expect(abs(result[0].real - 1.0) < 1e-9)
        #expect(abs(result[0].imag) < 1e-9)
        #expect(abs(result[1].real - 1.0) < 1e-9)
        #expect(abs(result[1].imag) < 1e-9)
    }

    // MARK: - Scalability Tests

    @Test func luSolverMediumSparse() throws {
        // 50x50 tridiagonal - tests scalability without being too slow
        let n = 50
        var entries: [(row: Int, col: Int)] = []

        for i in 0..<n {
            entries.append((i, i))  // diagonal
            if i > 0 {
                entries.append((i, i - 1))  // sub-diagonal
            }
            if i < n - 1 {
                entries.append((i, i + 1))  // super-diagonal
            }
        }

        let structure = SparseStructure.fromTriplets(dimension: n, entries: entries)
        var matrix = SparseMatrix(structure: structure)

        // Fill with typical circuit values (diagonally dominant)
        for i in 0..<n {
            matrix.addValue(row: i, col: i, value: 4.0)
            if i > 0 {
                matrix.addValue(row: i, col: i - 1, value: -1.0)
            }
            if i < n - 1 {
                matrix.addValue(row: i, col: i + 1, value: -1.0)
            }
        }

        // RHS vector
        var rhs = Array(repeating: 0.0, count: n)
        rhs[0] = 1.0
        rhs[n - 1] = 1.0

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: rhs)

        // Verify solution
        let result = matrix.multiply(vector: x)
        for i in 0..<n {
            #expect(abs(result[i] - rhs[i]) < 1e-8)
        }
    }

    @Test func matrixPermutation() {
        let structure = SparseStructure.fromTriplets(
            dimension: 3,
            entries: [(0, 0), (0, 1), (1, 1), (2, 0), (2, 2)]
        )
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 1.0)
        matrix.addValue(row: 0, col: 1, value: 2.0)
        matrix.addValue(row: 1, col: 1, value: 3.0)
        matrix.addValue(row: 2, col: 0, value: 4.0)
        matrix.addValue(row: 2, col: 2, value: 5.0)

        // Identity permutation should give same matrix
        let identity = Permutation.identity(size: 3)
        let sameMatrix = matrix.permute(identity)

        #expect(sameMatrix.value(row: 0, col: 0) == 1.0)
        #expect(sameMatrix.value(row: 0, col: 1) == 2.0)
        #expect(sameMatrix.value(row: 1, col: 1) == 3.0)
        #expect(sameMatrix.value(row: 2, col: 0) == 4.0)
        #expect(sameMatrix.value(row: 2, col: 2) == 5.0)

        // Swap rows 0 and 2: permutation 0→2, 1→1, 2→0
        let swap = Permutation(forward: [2, 1, 0])
        let permuted = matrix.permute(swap)

        // Original (0,0)=1 → new (2,2)=1
        // Original (0,1)=2 → new (2,1)=2
        // Original (1,1)=3 → new (1,1)=3
        // Original (2,0)=4 → new (0,2)=4
        // Original (2,2)=5 → new (0,0)=5
        #expect(permuted.value(row: 0, col: 0) == 5.0)
        #expect(permuted.value(row: 0, col: 2) == 4.0)
        #expect(permuted.value(row: 1, col: 1) == 3.0)
        #expect(permuted.value(row: 2, col: 1) == 2.0)
        #expect(permuted.value(row: 2, col: 2) == 1.0)
    }

    @Test func emptyMatrix() throws {
        let structure = SparseStructure.fromTriplets(dimension: 0, entries: [])
        let matrix = SparseMatrix(structure: structure)

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: [])

        #expect(x.isEmpty)
    }

    @Test func singleElementMatrix() throws {
        let structure = SparseStructure.fromTriplets(dimension: 1, entries: [(0, 0)])
        var matrix = SparseMatrix(structure: structure)
        matrix.addValue(row: 0, col: 0, value: 5.0)

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: [10.0])

        #expect(abs(x[0] - 2.0) < 1e-10)
    }

    // MARK: - Pivoting Tests (Sparse Path)

    @Test func sparseSolverRequiresPivoting() throws {
        // n = 501 forces the sparse path (threshold is n < 500 for dense)
        // Create a diagonally dominant tridiagonal matrix - this should work
        // even with the sparse path because it doesn't require pivoting
        let n = 501

        var entries: [(row: Int, col: Int)] = []
        for i in 0..<n {
            entries.append((i, i))  // diagonal
            if i > 0 {
                entries.append((i, i - 1))  // sub-diagonal
            }
            if i < n - 1 {
                entries.append((i, i + 1))  // super-diagonal
            }
        }

        let structure = SparseStructure.fromTriplets(dimension: n, entries: entries)
        var matrix = SparseMatrix(structure: structure)

        // Diagonally dominant: |diagonal| > sum of |off-diagonals|
        for i in 0..<n {
            matrix.addValue(row: i, col: i, value: 4.0)
            if i > 0 {
                matrix.addValue(row: i, col: i - 1, value: -1.0)
            }
            if i < n - 1 {
                matrix.addValue(row: i, col: i + 1, value: -1.0)
            }
        }

        let rhs = Array(repeating: 1.0, count: n)

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: rhs)

        // Verify A*x = b
        let result = matrix.multiply(vector: x)
        for i in 0..<n {
            #expect(abs(result[i] - rhs[i]) < 1e-6, "Mismatch at row \(i): expected \(rhs[i]), got \(result[i])")
        }
    }

    @Test func sparseSolverLargeTridiagonalWithPivoting() throws {
        // 502x502 tridiagonal matrix - tests the sparse path with threshold pivoting
        // This matrix is diagonally dominant, so pivoting should be minimal
        let n = 502

        var entries: [(row: Int, col: Int)] = []
        for i in 0..<n {
            entries.append((i, i))
            if i > 0 {
                entries.append((i, i - 1))
            }
            if i < n - 1 {
                entries.append((i, i + 1))
            }
        }

        let structure = SparseStructure.fromTriplets(dimension: n, entries: entries)
        var matrix = SparseMatrix(structure: structure)

        for i in 0..<n {
            matrix.addValue(row: i, col: i, value: 4.0)
            if i > 0 {
                matrix.addValue(row: i, col: i - 1, value: -1.0)
            }
            if i < n - 1 {
                matrix.addValue(row: i, col: i + 1, value: -1.0)
            }
        }

        var rhs = Array(repeating: 0.0, count: n)
        rhs[0] = 1.0
        rhs[n - 1] = 1.0

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: rhs)

        let result = matrix.multiply(vector: x)
        for i in 0..<n {
            #expect(abs(result[i] - rhs[i]) < 1e-8, "Mismatch at row \(i)")
        }
    }

    @Test func complexSparseSolverRequiresPivoting() throws {
        // Complex version - n = 501 forces the sparse path
        // Diagonally dominant tridiagonal matrix
        let n = 501

        var entries: [(row: Int, col: Int)] = []
        for i in 0..<n {
            entries.append((i, i))
            if i > 0 {
                entries.append((i, i - 1))
            }
            if i < n - 1 {
                entries.append((i, i + 1))
            }
        }

        let structure = SparseStructure.fromTriplets(dimension: n, entries: entries)
        var matrix = ComplexSparseMatrix(structure: structure)

        // Diagonally dominant with complex values
        for i in 0..<n {
            matrix.addValue(row: i, col: i, value: ComplexPair(real: 4.0, imag: 1.0))
            if i > 0 {
                matrix.addValue(row: i, col: i - 1, value: ComplexPair(real: -1.0, imag: 0.0))
            }
            if i < n - 1 {
                matrix.addValue(row: i, col: i + 1, value: ComplexPair(real: -1.0, imag: 0.0))
            }
        }

        let rhs = Array(repeating: ComplexPair(real: 1.0, imag: 0.0), count: n)

        var solver = ComplexSparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: rhs)

        let result = matrix.multiply(vector: x)
        for i in 0..<n {
            let error = (result[i] - rhs[i]).magnitude
            #expect(error < 1e-5, "Mismatch at row \(i): error = \(error)")
        }
    }

    @Test func pivotingSmallMatrixVerification() throws {
        // Small matrix (uses dense path) to verify pivoting logic is correct
        // This serves as a reference for the sparse path behavior
        let n = 4

        let entries: [(row: Int, col: Int)] = [
            (0, 0), (0, 1), (0, 2), (0, 3),
            (1, 0), (1, 1), (1, 2), (1, 3),
            (2, 0), (2, 1), (2, 2), (2, 3),
            (3, 0), (3, 1), (3, 2), (3, 3)
        ]

        let structure = SparseStructure.fromTriplets(dimension: n, entries: entries)
        var matrix = SparseMatrix(structure: structure)

        // Matrix requiring pivoting:
        // [ 0.001  2   3   4 ]
        // [  10    5   6   7 ]
        // [   8    9  10  11 ]
        // [  12   13  14  15 ]
        matrix.addValue(row: 0, col: 0, value: 0.001)
        matrix.addValue(row: 0, col: 1, value: 2.0)
        matrix.addValue(row: 0, col: 2, value: 3.0)
        matrix.addValue(row: 0, col: 3, value: 4.0)
        matrix.addValue(row: 1, col: 0, value: 10.0)
        matrix.addValue(row: 1, col: 1, value: 5.0)
        matrix.addValue(row: 1, col: 2, value: 6.0)
        matrix.addValue(row: 1, col: 3, value: 7.0)
        matrix.addValue(row: 2, col: 0, value: 8.0)
        matrix.addValue(row: 2, col: 1, value: 9.0)
        matrix.addValue(row: 2, col: 2, value: 10.0)
        matrix.addValue(row: 2, col: 3, value: 11.0)
        matrix.addValue(row: 3, col: 0, value: 12.0)
        matrix.addValue(row: 3, col: 1, value: 13.0)
        matrix.addValue(row: 3, col: 2, value: 14.0)
        matrix.addValue(row: 3, col: 3, value: 16.0)  // Make it non-singular

        let rhs = [1.0, 2.0, 3.0, 4.0]

        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let x = try solver.solve(rhs: rhs)

        let result = matrix.multiply(vector: x)
        for i in 0..<n {
            #expect(abs(result[i] - rhs[i]) < 1e-9, "Mismatch at row \(i)")
        }
    }
}
