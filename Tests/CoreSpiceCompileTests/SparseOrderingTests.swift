import Synchronization
import Testing
@testable import CoreSpiceCompile

@Suite("Sparse Ordering Contract Tests")
struct SparseOrderingTests {
    @Test func stableTiesAndInverseMapping() throws {
        let structure = try SparseStructure.fromTriplets(dimension: 8, entries: [(0, 1), (1, 2), (3, 4)])
        let result = try AMDOrdering.compute(structure: structure)
        #expect(result.inverse == referenceOrder(structure))
        for position in result.inverse.indices {
            #expect(result.forward[result.inverse[position]] == position)
        }
        #expect(try MinimumDegreeOrdering.compute(structure: structure) == result)
    }

    @Test func freshTriangleGraphsPreservePermutationAndChargedWork() throws {
        var expectedOrder: Permutation?
        var expectedWork: Int?
        // Each call allocates new Set storage with its own hash seed.
        for _ in 0..<64 {
            let structure = try SparseStructure.fromTriplets(
                dimension: 3, entries: [(0, 1), (0, 2), (1, 2)])
            let control = OrderingTestControl()
            let order = try AMDOrdering.compute(structure: structure, control: control)
            if let expectedOrder, let expectedWork {
                #expect(order == expectedOrder)
                #expect(control.work == expectedWork)
            } else {
                expectedOrder = order
                expectedWork = control.work
            }
        }
    }

    @Test func activeFillMatchesIndependentScanReference() throws {
        var seed: UInt64 = 731
        for n in 2...18 {
            var entries: [(row: Int, col: Int)] = []
            for row in 0..<n {
                for column in 0..<n {
                    seed = seed &* 6364136223846793005 &+ 1
                    if seed >> 60 < 3 { entries.append((row, column)) }
                }
            }
            let structure = try SparseStructure.fromTriplets(dimension: n, entries: entries)
            #expect(try AMDOrdering.compute(structure: structure).inverse == referenceOrder(structure))
        }
    }

    @Test func diagonalOrderingWorkDoesNotScanDimensionPerElimination() throws {
        let n = 2_048
        let structure = try SparseStructure.fromTriplets(
            dimension: n, entries: (0..<n).map { ($0, $0) })
        let control = OrderingTestControl()
        do {
            let permutation = try AMDOrdering.compute(structure: structure, control: control)
            #expect(permutation.forward == Array(0..<n))
            #expect(control.work < n * 40)
            #expect(control.liveBytes > 0)
            withExtendedLifetime(permutation) {}
        }
        #expect(control.liveBytes == 0)
    }

    @Test func chainAndStarHaveSparseControlledWork() throws {
        let n = 512
        let chain = try SparseStructure.fromTriplets(
            dimension: n, entries: (0..<(n - 1)).map { ($0, $0 + 1) })
        let star = try SparseStructure.fromTriplets(
            dimension: n, entries: (1..<n).map { (0, $0) })
        for structure in [chain, star] {
            let control = OrderingTestControl()
            let result = try AMDOrdering.compute(structure: structure, control: control)
            #expect(result.forward.sorted() == Array(0..<n))
            #expect(control.work < n * 100)
        }
    }

    @Test func typedRefusalAndCancellationReleaseTemporaryStorage() throws {
        let structure = try SparseStructure.fromTriplets(
            dimension: 5, entries: [(0, 1), (0, 2), (1, 3), (2, 4)])
        for failure in [OrderingTestFailure.work, .storage, .cancelled] {
            let control = OrderingTestControl(failure: failure)
            #expect(throws: failure) {
                _ = try AMDOrdering.compute(structure: structure, control: control)
            }
            #expect(control.liveBytes == 0)
        }
    }

    @Test func unsymmetricClosureIncludesTransitiveLowerFillWithoutMirroring() throws {
        let structure = try SparseStructure.fromTriplets(
            dimension: 4,
            entries: [(0, 0), (0, 1), (1, 1), (1, 3), (2, 0), (2, 2), (3, 3)])
        let analysis = try SymbolicAnalysis.analyze(
            structure: structure, ordering: .identity(size: 4))
        #expect(analysis.factorizationStructure.rowPointers == [0, 2, 4, 8, 9])
        #expect(analysis.factorizationStructure.columnIndices == [0, 1, 1, 3, 0, 1, 2, 3, 3])
        #expect(analysis.lRowPointers == [0, 0, 0, 2, 2])
        #expect(analysis.lColumnIndices == [0, 1])
        #expect(analysis.uColumnIndices == [0, 1, 1, 3, 2, 3, 3])
        #expect(analysis.fillInCount == 2)
    }

    @Test func symbolicMissingDiagonalAndInvalidPermutation() throws {
        let structure = try SparseStructure.fromTriplets(dimension: 3, entries: [(0, 2)])
        let control = OrderingTestControl()
        do {
            let analysis = try SymbolicAnalysis.analyze(
                structure: structure, ordering: .identity(size: 3), control: control)
            #expect(analysis.fillInCount == 3)
            #expect(analysis.factorizationStructure.columnIndices == [0, 2, 1, 2])
            #expect(control.liveBytes > 0)
            withExtendedLifetime(analysis) {}
        }
        #expect(control.liveBytes == 0)
        #expect(throws: SparseOrderingError.invalidPermutation) {
            _ = try SymbolicAnalysis.analyze(
                structure: structure,
                ordering: Permutation(forward: [0, 0, 2], inverse: [0, 1, 2]))
        }
    }

    private func referenceOrder(_ structure: SparseStructure) -> [Int] {
        let n = structure.dimension
        var edges = Array(repeating: Array(repeating: false, count: n), count: n)
        var active = Array(repeating: true, count: n)
        for row in 0..<n {
            for index in structure.rowPointers[row]..<structure.rowPointers[row + 1] {
                let column = structure.columnIndices[index]
                if row != column { edges[row][column] = true; edges[column][row] = true }
            }
        }
        var order: [Int] = []
        for _ in 0..<n {
            var best = -1
            var degree = Int.max
            for row in 0..<n where active[row] {
                let count = (0..<n).filter { active[$0] && edges[row][$0] }.count
                if count < degree { best = row; degree = count }
            }
            let neighbors = (0..<n).filter { active[$0] && edges[best][$0] }
            active[best] = false
            for row in neighbors {
                for column in neighbors where row != column { edges[row][column] = true }
            }
            order.append(best)
        }
        return order
    }
}

private enum OrderingTestFailure: Error, Sendable, Equatable {
    case work, storage, cancelled
}

private final class OrderingTestControl: LinearSolverExecutionControlling {
    private struct State {
        var work = 0
        var liveBytes = 0
        var reservations = 0
    }
    private let state = Mutex(State())
    private let failure: OrderingTestFailure?

    init(failure: OrderingTestFailure? = nil) { self.failure = failure }
    var work: Int { state.withLock { $0.work } }
    var liveBytes: Int { state.withLock { $0.liveBytes } }

    func checkpoint(workUnits: Int) throws {
        let work = state.withLock { state in state.work += workUnits; return state.work }
        if failure == .cancelled && work > 12 { throw OrderingTestFailure.cancelled }
        if failure == .work && work > 12 { throw OrderingTestFailure.work }
    }

    func reserveStorage(byteCount: Int) throws -> any Sendable {
        try state.withLock { state in
            state.reservations += 1
            if failure == .storage && state.reservations == 5 { throw OrderingTestFailure.storage }
            state.liveBytes += byteCount
        }
        return OrderingTestLease(owner: self, byteCount: byteCount)
    }

    func release(_ byteCount: Int) { state.withLock { $0.liveBytes -= byteCount } }
}

private final class OrderingTestLease: Sendable {
    let owner: OrderingTestControl
    let byteCount: Int
    init(owner: OrderingTestControl, byteCount: Int) {
        self.owner = owner
        self.byteCount = byteCount
    }
    deinit { owner.release(byteCount) }
}
