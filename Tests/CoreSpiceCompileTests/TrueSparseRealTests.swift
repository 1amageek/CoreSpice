import Synchronization
import Testing
@testable import CoreSpiceCompile

@Suite("Complete real sparse LU", .timeLimit(.minutes(1)))
struct TrueSparseRealTests {
    @Test(arguments: [499, 500, 501], [false, true])
    func updatedSchurPivotAcrossFormerCrossover(dimension: Int, ordering: Bool) throws {
        // The second original diagonal is nonzero, but its updated Schur pivot is zero.
        var entries = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (2, 0), (2, 2)]
        for row in 3..<dimension { entries.append((row, row)) }
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: dimension, entries: entries))
        for (row, col) in entries { matrix.addValue(row: row, col: col, value: 1) }
        let expected = (0..<dimension).map { Double($0 % 7) - 3 }
        var solver = SparseLUSolver(useAMDOrdering: ordering)
        try solver.factorize(matrix: matrix)
        let rhs = try matrix.multiply(vector: expected)
        let actual = try solver.solve(rhs: rhs)
        expectSolution(actual, expected: expected)
        expectSolution(try matrix.multiply(vector: actual), expected: rhs)
    }

    @Test(arguments: [false, true])
    func seededNonsymmetricSystemsMatchIndependentReference(ordering: Bool) throws {
        var seed: UInt64 = 0x91a2_b3c4_d5e6_f708
        for dimension in [4, 9, 17, 31] {
            var dense = Array(repeating: Array(repeating: 0.0, count: dimension), count: dimension)
            for row in 0..<dimension {
                var magnitude = 0.0
                for col in 0..<dimension where col != row {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    if seed % 5 == 0 {
                        let value = Double(Int((seed >> 32) % 19) - 9) / 4
                        dense[row][col] = value
                        magnitude += abs(value)
                    }
                }
                dense[row][row] = magnitude + 1
            }
            // Row permutation forces numeric row pivoting without losing nonsymmetric sparsity.
            dense.swapAt(0, dimension - 1)
            let matrix = try sparseMatrix(dense)
            let rhs = (0..<dimension).map { Double(($0 * 7) % 11) - 5 }
            var solver = SparseLUSolver(useAMDOrdering: ordering)
            try solver.factorize(matrix: matrix)
            let actual = try solver.solve(rhs: rhs)
            expectSolution(actual, expected: try denseReference(dense, rhs: rhs))
            expectSolution(try matrix.multiply(vector: actual), expected: rhs)
        }
    }

    @Test func numericPivotAndFillChangeWithoutReusingStaleNumericState() throws {
        let first = [[1.0, 2, 0], [10, 1, 4], [0, 3, 5]]
        var second = first
        second[0][0] = 20
        second[1][0] = 0.02
        second[2][1] = 0.01
        var solver = SparseLUSolver(useAMDOrdering: false)
        var statistics: [SparseFactorizationStatistics] = []
        for dense in [first, second, first] {
            let matrix = try sparseMatrix(dense)
            try solver.factorize(matrix: matrix)
            statistics.append(solver.statistics)
            let rhs = [1.0, -2, 3]
            expectSolution(try solver.solve(rhs: rhs), expected: try denseReference(dense, rhs: rhs))
        }
        #expect(statistics.map(\.structuralAnalyses) == [1, 1, 1])
        #expect(statistics.map(\.numericFactorizations) == [1, 2, 3])
        #expect(statistics[0].pivotInterchanges > 0)
        #expect(statistics[0].pivotInterchanges != statistics[1].pivotInterchanges)
        #expect(statistics[0].factorNonZeroCount != statistics[1].factorNonZeroCount)
        #expect(statistics[0].factorNonZeroCount == statistics[2].factorNonZeroCount)
        solver.useAMDOrdering = true
        try solver.factorize(matrix: sparseMatrix(first))
        #expect(solver.statistics.structuralAnalyses == 2)
        let changedStructure = try sparseMatrix([[4, 1], [0, 2]])
        try solver.factorize(matrix: changedStructure)
        #expect(solver.statistics.structuralAnalyses == 3)
        expectSolution(try solver.solve(rhs: [6, 4]), expected: [1, 2])
    }

    @Test(arguments: [1e-200, 1e200])
    func scaleDoesNotImposeAbsoluteSingularityFloor(scale: Double) throws {
        let matrix = try sparseMatrix([[2 * scale, -scale], [scale, 3 * scale]])
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: matrix)
        expectSolution(try solver.solve(rhs: [4 * scale, -5 * scale]), expected: [1, -2])
    }

    @Test func leastRepresentableNonzeroPivotRemainsUsable() throws {
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: sparseMatrix([[Double.leastNonzeroMagnitude]]))
        #expect(try solver.solve(rhs: [Double.leastNonzeroMagnitude]) == [1])
    }

    @Test func singularStructuralMissAndNonfiniteFailuresInvalidateOldFactors() throws {
        let valid = try sparseMatrix([[2, 0], [0, 3]])
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: valid)
        #expect(throws: CompileError.singularMatrix) {
            try solver.factorize(matrix: sparseMatrix([[1, 2], [2, 4]]))
        }
        expectStaleRefusal(&solver, dimension: 2)
        try solver.factorize(matrix: valid)
        var missed = valid
        missed.addValue(row: 0, col: 1, value: 1)
        do {
            try solver.factorize(matrix: missed)
            Issue.record("An out-of-pattern stamp must be rejected")
        } catch CompileError.incompatibleStructure {}
        expectStaleRefusal(&solver, dimension: 2)
        for value in [Double.nan, .infinity, -.infinity] {
            try solver.factorize(matrix: valid)
            #expect(throws: SparseSolverError.nonFiniteMatrixValue(index: 0)) {
                try solver.factorize(matrix: sparseMatrix([[value, 0], [0, 1]]))
            }
            expectStaleRefusal(&solver, dimension: 2)
        }
        try solver.factorize(matrix: valid)
        expectSolution(try solver.solve(rhs: [4, 9]), expected: [2, 3])
    }

    @Test func nonfiniteRHSAndArithmeticOverflowKeepTypedFailures() throws {
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: sparseMatrix([[1]]))
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: SparseSolverError.nonFiniteRHSValue(index: 0)) {
                _ = try solver.solve(rhs: [value])
            }
            var result = [0.0]
            #expect(throws: SparseSolverError.nonFiniteRHSValue(index: 0)) {
                try solver.solve(rhs: [value], into: &result)
            }
        }
        try solver.factorize(matrix: sparseMatrix([[Double.leastNonzeroMagnitude]]))
        #expect(throws: SparseSolverError.nonFiniteArithmetic) {
            _ = try solver.solve(rhs: [Double.greatestFiniteMagnitude])
        }
        #expect(throws: SparseSolverError.nonFiniteArithmetic) {
            try solver.factorize(matrix: sparseMatrix([[1e308, 1e308], [-1e308, 1e308]]))
        }
        expectStaleRefusal(&solver, dimension: 2)
    }

    @Test func zeroSizeShapesAndMultipleRightHandSides() throws {
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: sparseMatrix([]))
        #expect(try solver.solve(rhs: []) == [])
        var empty: [Double] = []
        try solver.solve(rhs: [], into: &empty)
        let matrix = try sparseMatrix([[0, 2, 1], [3, 1, 0], [1, 0, 4]])
        try solver.factorize(matrix: matrix)
        let before = solver.statistics
        for expected in [[1.0, 2, 3], [-2, 0, 5], [0, 0, 0]] {
            let rhs = try matrix.multiply(vector: expected)
            var result = [99.0, 99, 99]
            try solver.solve(rhs: rhs, into: &result)
            expectSolution(result, expected: expected)
            expectSolution(try solver.solve(rhs: rhs), expected: expected)
        }
        #expect(solver.statistics == before)
        var result = [7.0, 8, 9]
        #expect(throws: CompileError.vectorDimensionMismatch(vector: "rhs", expected: 3, actual: 2)) {
            try solver.solve(rhs: [1, 2], into: &result)
        }
        #expect(result == [7, 8, 9])
        var short = [7.0, 8]
        #expect(throws: CompileError.vectorDimensionMismatch(vector: "result", expected: 3, actual: 2)) {
            try solver.solve(rhs: [1, 2, 3], into: &short)
        }
        #expect(short == [7, 8])
        #expect(throws: CompileError.vectorDimensionMismatch(vector: "rhs", expected: 3, actual: 1)) {
            _ = try solver.solve(rhs: [1])
        }
    }

    @Test func capacityAndWorkRefusalsPrecedeBufferAllocation() throws {
        let matrix = try bandMatrix(dimension: 2_000, tridiagonal: true)
        for control in [Control(capacity: 0), Control(workLimit: 0)] {
            var solver = SparseLUSolver(useAMDOrdering: false)
            try solver.configureExecution(control)
            let expected: Refusal = control.capacity == 0 ? .capacity : .work
            #expect(throws: expected) { try solver.factorize(matrix: matrix) }
            #expect(solver.statistics.bufferAllocations == 0)
            #expect(control.snapshot.liveBytes == 0)
            #expect(control.snapshot.reservations == 0)
            expectStaleRefusal(&solver, dimension: matrix.dimension)
        }
    }

    @Test func cancellationDuringNumericRefactorThenFreshControllerRetry() throws {
        let matrix = try bandMatrix(dimension: 2_000, tridiagonal: true)
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: matrix)
        // Cached validation/reset cost nnz+n. Allow two partial 256-unit batches plus
        // two numeric batches so cancellation follows completed numeric traversal.
        let cancellationWork = matrix.structure.nonZeroCount + matrix.dimension + 4 * 256
        let cancelled = Control(cancelAtChargedWork: cancellationWork)
        try solver.configureExecution(cancelled)
        #expect(throws: Refusal.cancelled) { try solver.factorize(matrix: matrix) }
        #expect(cancelled.snapshot.chargedWork >= cancellationWork - 256)
        #expect(solver.statistics.lowerNonZeroCount > 0)
        #expect(solver.statistics.numericFactorizations == 1)
        expectStaleRefusal(&solver, dimension: matrix.dimension)
        let retry = Control()
        try solver.configureExecution(retry)
        try solver.factorize(matrix: matrix)
        expectSolution(try solver.solve(rhs: matrix.multiply(vector: Array(repeating: 1, count: 2_000))),
                       expected: Array(repeating: 1, count: 2_000))
        #expect(solver.statistics.numericFactorizations == 2)
    }

    @Test func cancelledStructureShrinkCanRetryBothOriginalAndReplacementShapes() throws {
        let original = try bandMatrix(dimension: 100, tridiagonal: false)
        let replacement = try bandMatrix(dimension: 80, tridiagonal: false)
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.factorize(matrix: original)
        // Replacement payload and workspace are the two admissions preceding the
        // post-allocation checkpoint; cached structure publication has not happened.
        let cancelled = Control(cancelOnZeroCheckpointAfterReservations: 2)
        try solver.configureExecution(cancelled)
        #expect(throws: Refusal.cancelled) { try solver.factorize(matrix: replacement) }
        #expect(cancelled.snapshot.reservations == 2)
        #expect(cancelled.snapshot.cancelled)
        expectStaleRefusal(&solver, dimension: original.dimension)
        for matrix in [original, replacement] {
            try solver.configureExecution(Control())
            try solver.factorize(matrix: matrix)
            let expected = (0..<matrix.dimension).map { Double($0 % 7) - 3 }
            expectSolution(try solver.solve(rhs: matrix.multiply(vector: expected)), expected: expected)
        }
    }

    @Test func solverCopiesKeepIndependentFactorsAndReleaseLeasesExactlyOnce() throws {
        let control = Control()
        var original: SparseLUSolver?
        var copy: SparseLUSolver?
        do {
            var solver = SparseLUSolver(useAMDOrdering: false)
            try solver.configureExecution(control)
            try solver.factorize(matrix: sparseMatrix([[0, 2], [3, 1]]))
            original = solver
            copy = solver
        }
        let initial = control.snapshot
        #expect(initial.liveBytes > 0)
        try copy?.factorize(matrix: sparseMatrix([[4, 1], [0, 2]]))
        expectSolution(try #require(original).solve(rhs: [4, 5]), expected: [1, 2])
        expectSolution(try #require(copy).solve(rhs: [6, 4]), expected: [1, 2])
        #expect(control.snapshot.peakBytes > initial.liveBytes)
        withExtendedLifetime(original) {}
        original = nil
        #expect(control.snapshot.liveBytes > 0)
        withExtendedLifetime(copy) {}
        copy = nil
        let final = control.snapshot
        #expect(final.liveBytes == 0)
        #expect(final.releases == final.reservations)
        #expect(!final.invalidRelease)
    }

    @Test(arguments: [2_000, 20_000], [false, true])
    func sparseBandsUseLinearWorkAndManagedPayload(dimension: Int, tridiagonal: Bool) throws {
        let matrix = try bandMatrix(dimension: dimension, tridiagonal: tridiagonal)
        // For a no-pivot band, at most three reached rows and two factor entries per column.
        // CSC/work vectors and two nnz-sized factor capacities require < 256*n + 1024 bytes.
        // Factorization takes <=64*n operations plus admission rounding. A solve adds
        // 3*n row/column visits, <=2*(n-1) off-diagonal updates and one partial batch.
        let factorChargeLimit = 64 * dimension + 1_024
        let solveChargeLimit = 5 * dimension + 256
        let control = Control(capacity: 300 * dimension + 2_048,
                              workLimit: factorChargeLimit + solveChargeLimit)
        var solver = SparseLUSolver(useAMDOrdering: false)
        try solver.configureExecution(control)
        try solver.factorize(matrix: matrix)
        let stats = solver.statistics
        #expect(stats.inputNonZeroCount == (tridiagonal ? 3 * dimension - 2 : dimension))
        #expect(stats.lowerNonZeroCount == (tridiagonal ? dimension - 1 : 0))
        #expect(stats.upperNonZeroCount == (tridiagonal ? 2 * dimension - 1 : dimension))
        #expect(stats.factorCapacity <= 2 * matrix.structure.nonZeroCount)
        #expect(stats.workUnits <= 64 * dimension)
        #expect(stats.chargedWorkUnits <= factorChargeLimit)
        #expect(stats.managedBytes <= 256 * dimension + 1_024)
        #expect(stats.peakManagedBytes <= control.capacity)
        #expect(control.snapshot.peakBytes <= control.capacity)
        #expect(control.snapshot.chargedWork == stats.chargedWorkUnits)
        let expected = (0..<dimension).map { Double($0 % 5) - 2 }
        var result = Array(repeating: 0.0, count: dimension)
        try solver.solve(rhs: matrix.multiply(vector: expected), into: &result)
        expectSolution(result, expected: expected)
        let cumulativeWork = control.snapshot.chargedWork
        #expect(cumulativeWork - stats.chargedWorkUnits <= solveChargeLimit)
        #expect(cumulativeWork <= factorChargeLimit + solveChargeLimit)
    }

    private func sparseMatrix(_ dense: [[Double]]) throws -> SparseMatrix {
        var entries: [(Int, Int)] = []
        for row in dense.indices {
            for col in dense.indices where row == col || dense[row][col] != 0 { entries.append((row, col)) }
        }
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: dense.count, entries: entries))
        for (row, col) in entries { matrix.addValue(row: row, col: col, value: dense[row][col]) }
        return matrix
    }

    private func bandMatrix(dimension: Int, tridiagonal: Bool) throws -> SparseMatrix {
        var entries: [(Int, Int)] = []
        for row in 0..<dimension {
            if tridiagonal && row > 0 { entries.append((row, row - 1)) }
            entries.append((row, row))
            if tridiagonal && row + 1 < dimension { entries.append((row, row + 1)) }
        }
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: dimension, entries: entries))
        for (row, col) in entries { matrix.addValue(row: row, col: col, value: row == col ? 4 : (row > col ? -1 : 0.5)) }
        return matrix
    }

    private func expectSolution(_ actual: [Double], expected: [Double]) {
        #expect(actual.count == expected.count)
        for index in actual.indices {
            #expect(abs(actual[index] - expected[index]) <= 1e-10 * max(1, abs(expected[index])),
                    "Mismatch at index \(index)")
        }
    }

    private func expectStaleRefusal(_ solver: inout SparseLUSolver, dimension: Int) {
        let rhs = Array(repeating: 1.0, count: dimension)
        #expect(throws: CompileError.singularMatrix) { _ = try solver.solve(rhs: rhs) }
        var result = rhs
        #expect(throws: CompileError.singularMatrix) { try solver.solve(rhs: rhs, into: &result) }
    }

    // Independent row-oriented dense Gaussian elimination updates RHS during elimination.
    private func denseReference(_ matrix: [[Double]], rhs: [Double]) throws -> [Double] {
        var rows = matrix
        var result = rhs
        for column in rows.indices {
            var pivot = column
            for row in (column + 1)..<rows.count {
                if abs(rows[row][column]) > abs(rows[pivot][column]) { pivot = row }
            }
            guard rows[pivot][column] != 0 else { throw CompileError.singularMatrix }
            rows.swapAt(column, pivot)
            result.swapAt(column, pivot)
            for row in (column + 1)..<rows.count {
                let multiplier = rows[row][column] / rows[column][column]
                rows[row][column] = 0
                for entry in (column + 1)..<rows.count { rows[row][entry] -= multiplier * rows[column][entry] }
                result[row] -= multiplier * result[column]
            }
        }
        for row in rows.indices.reversed() {
            for col in (row + 1)..<rows.count { result[row] -= rows[row][col] * result[col] }
            result[row] /= rows[row][row]
        }
        return result
    }

    private enum Refusal: Error, Sendable, Equatable { case capacity, work, cancelled }

    private final class Control: LinearSolverExecutionControlling {
        struct State: Sendable {
            var liveBytes = 0, peakBytes = 0, reservations = 0, releases = 0
            var chargedWork = 0, positiveCheckpoints = 0
            var cancelled = false, invalidRelease = false
        }
        let capacity: Int
        private let workLimit: Int
        private let cancelAtChargedWork: Int?
        private let cancelOnZeroCheckpointAfterReservations: Int?
        private let state = Mutex(State())
        var snapshot: State { state.withLock { $0 } }

        init(capacity: Int = Int.max, workLimit: Int = Int.max, cancelAtChargedWork: Int? = nil,
             cancelOnZeroCheckpointAfterReservations: Int? = nil) {
            self.capacity = capacity
            self.workLimit = workLimit
            self.cancelAtChargedWork = cancelAtChargedWork
            self.cancelOnZeroCheckpointAfterReservations = cancelOnZeroCheckpointAfterReservations
        }

        func checkpoint(workUnits: Int) throws {
            try state.withLock { state in
                if workUnits > 0 {
                    state.positiveCheckpoints += 1
                    if let cancelAtChargedWork, workUnits >= cancelAtChargedWork - state.chargedWork {
                        state.cancelled = true
                    }
                }
                if workUnits == 0, let threshold = cancelOnZeroCheckpointAfterReservations,
                   state.reservations >= threshold {
                    state.cancelled = true
                }
                guard !state.cancelled else { throw Refusal.cancelled }
                guard workUnits >= 0, workUnits <= workLimit - state.chargedWork else { throw Refusal.work }
                state.chargedWork += workUnits
            }
        }

        func reserveStorage(byteCount: Int) throws -> any Sendable {
            try state.withLock { state in
                guard byteCount >= 0, byteCount <= capacity - state.liveBytes else { throw Refusal.capacity }
                state.liveBytes += byteCount
                state.peakBytes = max(state.peakBytes, state.liveBytes)
                state.reservations += 1
            }
            return Lease(owner: self, bytes: byteCount)
        }

        private final class Lease: Sendable {
            let owner: Control
            let bytes: Int
            init(owner: Control, bytes: Int) { self.owner = owner; self.bytes = bytes }
            deinit {
                owner.state.withLock { state in
                    state.invalidRelease = state.invalidRelease || state.liveBytes < bytes
                    state.liveBytes -= bytes
                    state.releases += 1
                }
            }
        }
    }
}
