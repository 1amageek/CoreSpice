import CoreSpiceCompile
import Synchronization
import Testing

@Suite("Sparse workspace admission after interrupted preparation", .timeLimit(.minutes(1)))
struct SparseWorkspaceAdmissionTests {
    @Test(arguments: [false, true])
    func interruptedInitialPreparationRetainsAdmissionThroughRefusedRetry(useAMD: Bool) throws {
        let matrix = try diagonal(dimension: 1_000)
        let interrupted = Control(cancelAfterInitializationWork: 15_003)
        let refused = Control(capacity: SparseLUSolver().statistics.managedBytes)
        let recovered = Control()
        var retained: SparseLUSolver?
        do {
            var solver = SparseLUSolver(useAMDOrdering: useAMD)
            try solver.configureExecution(interrupted)
            #expect(throws: Refusal.cancelled) { try solver.factorize(matrix: matrix) }
            #expect(solver.statistics.bufferAllocations == 13)
            let admitted = interrupted.snapshot.liveBytes
            #expect(admitted > refused.capacity)
            try solver.configureExecution(refused)
            #expect(throws: Refusal.capacity) { try solver.factorize(matrix: matrix) }
            #expect(refused.snapshot.reservations == 0)
            #expect(interrupted.snapshot.liveBytes == admitted)
            #expect(throws: CompileError.singularMatrix) { _ = try solver.solve(rhs: Array(repeating: 2, count: 1_000)) }
            try solver.configureExecution(recovered)
            try solver.factorize(matrix: matrix)
            #expect(try solver.solve(rhs: Array(repeating: 2, count: 1_000)) == Array(repeating: 1, count: 1_000))
            retained = solver
        }
        #expect(interrupted.snapshot.liveBytes == 0)
        #expect(refused.snapshot.liveBytes == 0)
        #expect(recovered.snapshot.liveBytes > 0)
        withExtendedLifetime(retained) {}
        retained = nil
        expectReleased(recovered)
        expectReleased(interrupted)
        expectReleased(refused)
    }

    @Test(arguments: [false, true])
    func interruptedShrinkPublishesMatchingPermutationAndCanRetryEitherShape(useAMD: Bool) throws {
        let original = try diagonal(dimension: 1_000)
        let replacement = try diagonal(dimension: 64)
        let initial = Control()
        let interrupted = Control(cancelAfterInitializationWork: 963)
        let refused = Control(capacity: 0)
        let recovered = Control()
        do {
            var solver = SparseLUSolver(useAMDOrdering: useAMD)
            try solver.configureExecution(initial)
            try solver.factorize(matrix: original)
            let priorAllocations = solver.statistics.bufferAllocations
            try solver.configureExecution(interrupted)
            #expect(throws: Refusal.cancelled) { try solver.factorize(matrix: replacement) }
            #expect(solver.statistics.bufferAllocations == priorAllocations + 13)
            // Natural permutations have no separate lease. Inspect their retained extent
            // to reject a smaller workspace estimate paired with the old large permutation.
            #expect(try retainedOrderingDimension(solver) == replacement.dimension)
            if useAMD { #expect(initial.snapshot.liveBytes == 0) }
            let admitted = interrupted.snapshot.liveBytes
            try solver.configureExecution(refused)
            #expect(throws: Refusal.capacity) { try solver.factorize(matrix: original) }
            #expect(interrupted.snapshot.liveBytes == admitted)
            #expect(throws: CompileError.singularMatrix) { _ = try solver.solve(rhs: Array(repeating: 2, count: 1_000)) }
            try solver.configureExecution(recovered)
            for matrix in [replacement, original] {
                try solver.factorize(matrix: matrix)
                #expect(try solver.solve(rhs: Array(repeating: 2, count: matrix.dimension)) == Array(repeating: 1, count: matrix.dimension))
            }
        }
        for control in [initial, interrupted, refused, recovered] { expectReleased(control) }
    }

    @Test func interruptedComplexPreparationRetainsAdmissionThroughRefusedRetry() throws {
        let real = try diagonal(dimension: 1_000)
        var matrix = ComplexSparseMatrix(structure: real.structure)
        for index in 0..<matrix.dimension { matrix.addValue(row: index, col: index, value: .init(real: 2)) }
        let interrupted = Control(cancelAfterInitializationWork: 15_003)
        let refused = Control(capacity: ComplexSparseLUSolver().statistics.managedBytes)
        let recovered = Control()
        do {
            var solver = ComplexSparseLUSolver(useAMDOrdering: false)
            try solver.configureExecution(interrupted)
            #expect(throws: Refusal.cancelled) { try solver.factorize(matrix: matrix) }
            #expect(solver.statistics.bufferAllocations == 13)
            let admitted = interrupted.snapshot.liveBytes
            try solver.configureExecution(refused)
            #expect(throws: Refusal.capacity) { try solver.factorize(matrix: matrix) }
            #expect(refused.snapshot.reservations == 0)
            #expect(interrupted.snapshot.liveBytes == admitted)
            let rhs = Array(repeating: ComplexPair(real: 2, imag: 0), count: matrix.dimension)
            #expect(throws: CompileError.singularMatrix) { _ = try solver.solve(rhs: rhs) }
            try solver.configureExecution(recovered)
            try solver.factorize(matrix: matrix)
            #expect(try solver.solve(rhs: rhs) == Array(repeating: ComplexPair(real: 1, imag: 0), count: matrix.dimension))
        }
        for control in [interrupted, refused, recovered] { expectReleased(control) }
    }

    private func diagonal(dimension: Int) throws -> SparseMatrix {
        let structure = try SparseStructure.fromTriplets(dimension: dimension, entries: (0..<dimension).map { ($0, $0) })
        var matrix = SparseMatrix(structure: structure)
        for index in 0..<dimension { matrix.addValue(row: index, col: index, value: 2) }
        return matrix
    }

    private func retainedOrderingDimension(_ solver: SparseLUSolver) throws -> Int {
        let kernel = try #require(Mirror(reflecting: solver).children.first { $0.label == "kernel" })
        let ordering = try #require(Mirror(reflecting: kernel.value).children.first { $0.label == "ordering" }?.value as? Permutation)
        return ordering.dimension
    }

    private func expectReleased(_ control: Control) {
        let state = control.snapshot
        #expect(state.liveBytes == 0)
        #expect(state.reservations == state.releases)
        #expect(!state.invalidRelease)
    }

    private enum Refusal: Error, Equatable { case capacity, cancelled }

    private final class Control: LinearSolverExecutionControlling {
        struct State: Sendable {
            var liveBytes = 0
            var reservations = 0
            var releases = 0
            var invalidRelease = false
            var initializationAdmitted = false
        }
        let capacity: Int
        private let cancelAfterInitializationWork: Int?
        private let state = Mutex(State())
        var snapshot: State { state.withLock { $0 } }

        init(capacity: Int = .max, cancelAfterInitializationWork: Int? = nil) {
            self.capacity = capacity
            self.cancelAfterInitializationWork = cancelAfterInitializationWork
        }

        func checkpoint(workUnits: Int) throws {
            try state.withLock {
                if let cancelAfterInitializationWork, workUnits == cancelAfterInitializationWork {
                    $0.initializationAdmitted = true
                }
                if workUnits == 0 && $0.initializationAdmitted { throw Refusal.cancelled }
            }
        }

        func reserveStorage(byteCount: Int) throws -> any Sendable {
            try state.withLock {
                guard byteCount >= 0, byteCount <= capacity - $0.liveBytes else { throw Refusal.capacity }
                $0.liveBytes += byteCount
                $0.reservations += 1
            }
            return Lease(owner: self, bytes: byteCount)
        }

        private final class Lease: Sendable {
            let owner: Control
            let bytes: Int
            init(owner: Control, bytes: Int) { self.owner = owner; self.bytes = bytes }
            deinit {
                owner.state.withLock {
                    $0.invalidRelease = $0.invalidRelease || $0.liveBytes < bytes
                    $0.liveBytes -= bytes
                    $0.releases += 1
                }
            }
        }
    }
}
