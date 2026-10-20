import CoreSpiceDevices
import CoreSpiceEvent
import Synchronization
import Testing
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile

@Suite("Validated sparse interval matrix regularity", .timeLimit(.minutes(1)))
struct ValidatedMatrixRegularityTests {
    private typealias Checker = ValidatedMatrixRegularity
    private typealias E = CompensatedEnclosure

    private func enclosure(_ value: Double, radius: Double = 0) throws -> E {
        try E(center: .init(high: value), radius: radius)
    }

    private func limits(_ n: Int, nonzeros: Int, bytes: Int = 1_000_000) -> Checker.Limits {
        .init(maximumDimension: n, maximumMatrixNonzeros: nonzeros,
            maximumInverseNonzeros: nonzeros, maximumWorkspaceBytes: bytes)
    }

    private func budget(_ n: Int = 1, work: Int = 5_000_000,
        dimensionLimit: Int? = nil) throws -> TransientExecutionBudget {
        try .init(limits: .init(maximumAcceptedSteps: 1, maximumSolveAttempts: 1,
            maximumNewtonIterations: 1, maximumSavedScalars: 1,
            maximumMatrixDimension: dimensionLimit ?? n, maximumWorkUnits: work,
            maximumBreakpoints: 1), dimension: n, nonZeroCount: 0, deviceCount: 0)
    }

    private func dense(_ n: Int) throws -> SparseStructure {
        try .init(dimension: n, rowPointers: (0...n).map { $0 * n },
            columnIndices: (0..<(n * n)).map { $0 % n })
    }

    private func check(_ matrix: SparseStructure, _ values: [E], _ inverse: SparseStructure,
        _ inverseValues: [Double], owner: TransientExecutionBudget? = nil,
        storage: RegularityStorage = .init(), cancellation: CancellationToken = .init(),
        limits selected: Checker.Limits? = nil) throws -> Checker.Result {
        try Checker.certify(matrix: matrix, values: values.span, inverse: inverse,
            inverseValues: inverseValues.span,
            limits: selected ?? limits(matrix.dimension, nonzeros: max(values.count, inverseValues.count)),
            budget: owner ?? budget(max(1, matrix.dimension)), storage: storage, cancellation: cancellation)
    }

    /// Test-only exact integer multiplication; both matrices have denominator d.
    private func rationalNorm(_ m: [Int64], _ r: [Int64], n: Int, d: Int64) -> Double {
        var maximum: Int64 = 0
        for i in 0..<n {
            var row: Int64 = 0
            for j in 0..<n {
                var residual: Int64 = i == j ? d * d : 0
                for k in 0..<n { residual -= r[i * n + k] * m[k * n + j] }
                row += abs(residual)
            }
            maximum = max(maximum, row)
        }
        return Double(maximum) / Double(d * d)
    }

    @Test func noncommutingDyadicProductUsesEveryRowAndCorrectOrder() throws {
        let pattern = try dense(2)
        let m = try [2.0, 1, 0, 1].map { try enclosure($0) }
        let r = [0.5, -0.25, 0, 1]
        let exact = rationalNorm([8, 4, 0, 4], [2, -1, 0, 4], n: 2, d: 4)
        #expect(exact == 0.25)
        let result = try check(pattern, m, pattern, r)
        #expect(result.dimension == 2)
        #expect(result.normUpperBound >= exact)
        #expect(result.normUpperBound < 0.25 + 0x1p-48)
        // M*R has norm 1/2, so this also detects reversed multiplication.
        #expect(result.normUpperBound < 0.5)
        #expect(m == [try enclosure(2), try enclosure(1), try enclosure(0), try enclosure(1)])
        #expect(r == [0.5, -0.25, 0, 1])
    }

    @Test func independentDyadicCornersAreAllEnclosed() throws {
        let pattern = try dense(2)
        let centers: [Int64] = [16, 8, 0, 8]
        let radii: [Int64] = [1, 1, 0, 1]
        let values = try centers.indices.map {
            try enclosure(Double(centers[$0]) / 8, radius: Double(radii[$0]) / 8)
        }
        let result = try check(pattern, values, pattern, [0.5, -0.25, 0, 1])
        var exactMaximum = 0.0
        for mask in 0..<16 {
            let corner = centers.indices.map { centers[$0] + ((mask & (1 << $0)) == 0 ? -radii[$0] : radii[$0]) }
            let exact = rationalNorm(corner, [4, -2, 0, 8], n: 2, d: 8)
            exactMaximum = max(exactMaximum, exact)
            #expect(result.normUpperBound >= exact)
        }
        #expect(exactMaximum == 0.40625)
        #expect(result.normUpperBound < 0.5)
    }

    @Test func actualSparseSolveProposalIsCheckedIndependently() throws {
        let pattern = try dense(2)
        var matrix = SparseMatrix(structure: pattern)
        for (index, value) in [2.0, 1, 1, 2].enumerated() { matrix.addValueDirect(at: index, value: value) }
        var solver = SparseLUSolver()
        try solver.factorize(matrix: matrix)
        let first = try solver.solve(rhs: [1, 0]), second = try solver.solve(rhs: [0, 1])
        var proposed = [first[0], second[0], first[1], second[1]]
        let values = try matrix.values.map { try enclosure($0) }
        let result = try check(pattern, values, pattern, proposed)
        #expect(result.normUpperBound < 0x1p-48)
        proposed[0] += 1
        #expect(throws: Checker.Failure.uncertified) { try check(pattern, values, pattern, proposed) }
    }

    @Test func distinctChargeValueAnchorsNeedNotShareADerivativeDirection() throws {
        // The columns (1,1) and (2,4) come from Q(t)=(t,t^2), at t=1 and t=2.
        // The lower checker knows only this matrix, not the source or anchor legality.
        let pattern = try dense(2)
        let values = try [1.0, 2, 1, 4].map { try enclosure($0) }
        let result = try check(pattern, values, pattern, [2, -1, -0.5, 0.5])
        #expect(result.normUpperBound < 0x1p-48)
    }

    @Test func compensatedLowCoordinatesAreNotProjectedAway() throws {
        let scalar = try dense(1)
        let value = try E(center: .init(high: 1, low: 0x1p-54))
        let result = try check(scalar, [value], scalar, [1])
        #expect(result.normUpperBound >= 0x1p-54)
        #expect(result.normUpperBound < 0x1p-53)
    }

    @Test func singularContainingIntervalWrongInverseAndStrictBoundaryRefuse() throws {
        let scalar = try dense(1)
        // Includes zero, although the center with the proposed R has zero residual.
        #expect(throws: Checker.Failure.uncertified) {
            try check(scalar, [enclosure(1, radius: 1)], scalar, [1])
        }
        for r in [0.0, 2.0, -1.0] {
            #expect(throws: Checker.Failure.uncertified) { try check(scalar, [enclosure(1)], scalar, [r]) }
        }
        let pattern = try dense(2)
        // Both residual diagonal entries vanish; an off-diagonal entry invalidates the certificate.
        #expect(throws: Checker.Failure.uncertified) {
            try check(pattern, [enclosure(1), enclosure(2), enclosure(0), enclosure(1)],
                pattern, [1, 0, 0, 1])
        }
        let empty = try SparseStructure(dimension: 1, rowPointers: [0, 0], columnIndices: [])
        #expect(throws: Checker.Failure.uncertified) { try check(empty, [], empty, []) }
    }

    @Test func tinyOffDiagonalTermsCannotDisappearAtTheStrictNormBoundary() throws {
        let n = 10
        let identity = try SparseStructure(dimension: n, rowPointers: Array(0...n), columnIndices: Array(0..<n))
        var pointers = [0, n], columns = Array(0..<n)
        var r = [1.0, -(1 - 0x1p-52)] + [Double](repeating: -0x1p-55, count: 8)
        for row in 1..<n { columns.append(row); pointers.append(columns.count); r.append(1) }
        let inverse = try SparseStructure(dimension: n, rowPointers: pointers, columnIndices: columns)
        // Exact row norm: (2^55-8 + 8)/2^55 = 1. Ordinary summation can lose all eight tiny terms.
        let numerator = (Int64(1) << 55) - 8 + 8
        #expect(numerator == Int64(1) << 55)
        #expect(throws: Checker.Failure.uncertified) {
            try check(identity, [E](repeating: enclosure(1), count: n), inverse, r)
        }
    }

    @Test func malformedInputsRefuseBeforeAnyWorkspaceReservation() throws {
        let scalar = try dense(1), storage = RegularityStorage()
        let zero = try SparseStructure(dimension: 0, rowPointers: [0], columnIndices: [])
        #expect(throws: Checker.Failure.invalidInput) { try check(zero, [], zero, [], storage: storage) }
        #expect(throws: Checker.Failure.invalidInput) { try check(scalar, [], scalar, [1], storage: storage) }
        let two = try dense(2)
        #expect(throws: Checker.Failure.invalidInput) {
            try check(scalar, [enclosure(1)], two, [1, 0, 0, 1], storage: storage)
        }
        let badPatterns = [
            SparseStructure(uncheckedDimension: 1, rowPointers: [0], columnIndices: [0]),
            .init(uncheckedDimension: 1, rowPointers: [1, 1], columnIndices: [0]),
            .init(uncheckedDimension: 1, rowPointers: [0, 0], columnIndices: [0]),
            .init(uncheckedDimension: 1, rowPointers: [0, 2], columnIndices: [0]),
            .init(uncheckedDimension: 1, rowPointers: [0, 1], columnIndices: [-1]),
            .init(uncheckedDimension: 1, rowPointers: [0, 1], columnIndices: [1]),
            .init(uncheckedDimension: 1, rowPointers: [0, 2], columnIndices: [0, 0]),
            .init(uncheckedDimension: 2, rowPointers: [0, 2, 1], columnIndices: [0])
        ]
        for pattern in badPatterns {
            let values = try [E](repeating: enclosure(1), count: pattern.nonZeroCount)
            let r = [Double](repeating: 1, count: pattern.nonZeroCount)
            #expect(throws: Checker.Failure.invalidCSR) {
                try check(pattern, values, pattern, r, storage: storage)
            }
        }
        for r in [Double.nan, .infinity, -.infinity] {
            #expect(throws: Checker.Failure.nonFiniteInput) {
                try check(scalar, [enclosure(1)], scalar, [r], storage: storage)
            }
        }
        let unboundedProjection = try enclosure(.greatestFiniteMagnitude, radius: .greatestFiniteMagnitude)
        #expect(throws: Checker.Failure.nonFiniteInput) {
            try check(scalar, [unboundedProjection], scalar, [1], storage: storage)
        }
        #expect(storage.snapshot.reservations == 0)
    }

    @Test func explicitCeilingsAndCheckedCapacityArithmeticPrecedeAllocation() throws {
        let scalar = try dense(1), storage = RegularityStorage()
        let needed = try Checker.workspaceByteCount(dimension: 1)
        #expect(throws: Checker.Failure.workspaceLimit) {
            try check(scalar, [enclosure(1)], scalar, [1], storage: storage,
                limits: limits(1, nonzeros: 1, bytes: needed - 1))
        }
        #expect(throws: Checker.Failure.invalidInput) {
            try check(scalar, [enclosure(1)], scalar, [1], storage: storage,
                limits: limits(1, nonzeros: 0))
        }
        #expect(throws: Checker.Failure.invalidInput) {
            let two = try dense(2)
            _ = try check(two, [enclosure(1), enclosure(0), enclosure(0), enclosure(1)], two,
                [1, 0, 0, 1], owner: budget(), storage: storage)
        }
        #expect(throws: TransientExecutionError.self) { try Checker.workspaceByteCount(dimension: Int.max) }
        let huge = SparseStructure(uncheckedDimension: Int.max, rowPointers: [], columnIndices: [])
        #expect(throws: TransientExecutionError.self) {
            try check(huge, [], huge, [], owner: budget(dimensionLimit: Int.max), storage: storage,
                limits: limits(Int.max, nonzeros: 0, bytes: Int.max))
        }
        #expect(storage.snapshot.reservations == 0)
    }

    @Test func cancellationAndStorageFailurePreserveCausesAndRefund() throws {
        let scalar = try dense(1), values = [try enclosure(1)]
        let cancelled = CancellationToken()
        cancelled.cancel()
        let before = RegularityStorage()
        do {
            _ = try check(scalar, values, scalar, [1], storage: before, cancellation: cancelled)
            Issue.record("Cancelled regularity check published a result")
        } catch AnalysisError.cancelled {}
        #expect(before.snapshot.reservations == 0)
        let during = CancellationToken(), admitted = RegularityStorage(cancelOnAdmission: during)
        do {
            _ = try check(scalar, values, scalar, [1], storage: admitted, cancellation: during)
            Issue.record("Cancellation during storage admission published a result")
        } catch AnalysisError.cancelled {}
        #expect(admitted.snapshot.reservations == 1 && admitted.snapshot.releases == 1)
        #expect(admitted.snapshot.live == 0)
        let denied = RegularityStorage(refuse: true)
        #expect(throws: RegularityStorage.Failure.denied) { try check(scalar, values, scalar, [1], storage: denied) }
        #expect(denied.snapshot.live == 0 && denied.snapshot.reservations == 0)
        _ = try check(scalar, values, scalar, [1], storage: before)
        #expect(before.snapshot.live == 0 && before.snapshot.releases == 1)
    }

    @Test func arithmeticAndWorkFailuresRefundWithoutResettingTheRunBudget() throws {
        let scalar = try dense(1), values = [try enclosure(1)]
        let measured = try budget(), storage = RegularityStorage()
        _ = try check(scalar, values, scalar, [1], owner: measured, storage: storage)
        let oneCall = measured.statistics.workUnits
        _ = try check(scalar, values, scalar, [1], owner: measured, storage: storage)
        #expect(measured.statistics.workUnits == 2 * oneCall)
        let exhausted = try budget(work: oneCall + 1)
        _ = try check(scalar, values, scalar, [1], owner: exhausted, storage: storage)
        #expect(throws: TransientExecutionError.self) {
            try check(scalar, values, scalar, [1], owner: exhausted, storage: storage)
        }
        #expect(exhausted.statistics.workUnits >= oneCall)
        // Work=11 admits initialization and row/R traversal, but refuses the first sparse product.
        #expect(throws: TransientExecutionError.self) {
            try check(scalar, values, scalar, [1], owner: budget(work: 11), storage: storage)
        }
        #expect(throws: NumericalStateError.arithmeticOverflow) {
            try check(scalar, [enclosure(.greatestFiniteMagnitude)], scalar, [2], storage: storage)
        }
        #expect(throws: Checker.Failure.uncertified) {
            try check(scalar, values, scalar, [0], storage: storage)
        }
        #expect(storage.snapshot.live == 0)
        #expect(storage.snapshot.reservations == storage.snapshot.releases)
    }

    @Test func structuralZeroTermsStillConsumeActualProductWork() throws {
        let scalar = try dense(1)
        let empty = try SparseStructure(dimension: 1, rowPointers: [0, 0], columnIndices: [])
        let withProduct = try budget(), withoutProduct = try budget()
        #expect(throws: Checker.Failure.uncertified) {
            try check(scalar, [enclosure(0)], scalar, [0], owner: withProduct)
        }
        #expect(throws: Checker.Failure.uncertified) {
            try check(empty, [], scalar, [0], owner: withoutProduct)
        }
        // One extra coordinate validation, numeric validation, and structural product.
        #expect(withProduct.statistics.workUnits == withoutProduct.statistics.workUnits + 3)
    }

    @Test(arguments: [false, true])
    func tenThousandSparseRowsUseOnlyLinearManagedWorkspace(tridiagonal: Bool) throws {
        let n = 10_000
        var pointers = [0], columns: [Int] = [], values: [E] = []
        for row in 0..<n {
            if tridiagonal && row > 0 { columns.append(row - 1); values.append(try enclosure(-0.125, radius: 0.015625)) }
            columns.append(row); values.append(try enclosure(2, radius: 0.015625))
            if tridiagonal && row + 1 < n { columns.append(row + 1); values.append(try enclosure(0.125, radius: 0.015625)) }
            pointers.append(columns.count)
        }
        let matrix = try SparseStructure(dimension: n, rowPointers: pointers, columnIndices: columns)
        let inverse = try SparseStructure(dimension: n, rowPointers: Array(0...n), columnIndices: Array(0..<n))
        let r = [Double](repeating: 0.5, count: n)
        let owner = try budget(n), storage = RegularityStorage()
        let started = ContinuousClock.now
        let result = try check(matrix, values, inverse, r, owner: owner, storage: storage)
        let elapsed = started.duration(to: .now)
        #expect(result.dimension == n && result.normUpperBound < 0.15)
        let expectedBytes = n * (MemoryLayout<E>.stride + MemoryLayout<Bool>.stride + MemoryLayout<Int>.stride)
            + MemoryLayout<[E]>.stride + MemoryLayout<[Bool]>.stride + MemoryLayout<[Int]>.stride
        #expect(storage.snapshot.peak == UInt64(expectedBytes))
        #expect(storage.snapshot.live == 0 && storage.snapshot.reservations == 1 && storage.snapshot.releases == 1)
        #expect(owner.statistics.workUnits < 30 * n)
        #expect(matrix.rowPointers == pointers && matrix.columnIndices == columns)
        for row in 0..<n {
            for index in pointers[row]..<pointers[row + 1] {
                let expected = columns[index] == row ? 2.0 : (columns[index] < row ? -0.125 : 0.125)
                #expect(values[index].center.high == expected && values[index].radius == 0.015625)
            }
            #expect(r[row] == 0.5)
        }
        print("regularity n=\(n) tridiagonal=\(tridiagonal) work=\(owner.statistics.workUnits) peakManagedBytes=\(storage.snapshot.peak) refunded=\(storage.snapshot.live == 0) elapsed=\(elapsed)")
    }
}

private final class RegularityStorage: AnalysisResultStorageAccounting, Sendable {
    enum Failure: Error { case denied, unexpectedResultReservation }
    struct State: Sendable {
        var live: UInt64 = 0
        var peak: UInt64 = 0
        var reservations = 0
        var releases = 0
    }
    private let state = Mutex(State())
    private let refuse: Bool
    private let cancelOnAdmission: CancellationToken?
    init(refuse: Bool = false, cancelOnAdmission: CancellationToken? = nil) {
        self.refuse = refuse; self.cancelOnAdmission = cancelOnAdmission
    }
    var snapshot: State { state.withLock { $0 } }
    func reserveResultScalars(_ capacity: Int) throws { throw Failure.unexpectedResultReservation }
    func reserveTemporaryBytes(_ bytes: UInt64) throws -> any Sendable {
        if refuse { throw Failure.denied }
        state.withLock { state in
            state.live += bytes
            state.peak = max(state.peak, state.live)
            state.reservations += 1
        }
        let lease = Lease(owner: self, bytes: bytes)
        cancelOnAdmission?.cancel()
        return lease
    }
    private final class Lease: Sendable {
        let owner: RegularityStorage
        let bytes: UInt64
        init(owner: RegularityStorage, bytes: UInt64) { self.owner = owner; self.bytes = bytes }
        deinit {
            owner.state.withLock { state in state.live -= bytes; state.releases += 1 }
        }
    }
}
