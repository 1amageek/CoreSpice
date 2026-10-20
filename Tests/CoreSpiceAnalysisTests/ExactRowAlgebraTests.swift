import Testing
import Synchronization
import CoreSpiceCompile
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Bounded exact row algebra", .timeLimit(.minutes(1)))
struct ExactRowAlgebraTests {
    typealias Algebra = ExactRowAlgebra
    typealias Scalar = Algebra.Scalar
    private func integer(_ value: Int64) -> Scalar {
        .init(negative: value < 0, words: value == 0 ? [] : [value.magnitude])
    }
    private func rows(_ values: [[Int64]]) -> Algebra.Rows {
        .init(rowCount: values.count, columnCount: values.first?.count ?? 1, values: values.flatMap { $0.map(integer) })
    }
    private func limits(bits: Int = 1_024, workspace: Int = 8_000_000, result: Int = 8_000_000) -> Algebra.Limits {
        .init(maximumRows: 64, maximumColumns: 64, maximumIntegerBits: bits,
            maximumWorkspaceBytes: workspace, maximumResultBytes: result)
    }
    private func setup(policy: Algebra.Limits? = nil, work: Int = 1_000_000_000,
                       token: CancellationToken = CancellationToken(), storage: Storage = Storage()) throws -> (Algebra, TransientExecutionBudget, Storage) {
        let numerical = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
            maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 100,
            maximumWorkUnits: work, maximumBreakpoints: 10)
        let budget = try TransientExecutionBudget(limits: numerical, dimension: 1, nonZeroCount: 1, deviceCount: 0)
        return (try Algebra(limits: policy ?? limits(), budget: budget, storage: storage, cancellation: token), budget, storage)
    }

    @Test func localIdentityCannotBePromotedThroughTheWrongIncidence() throws {
        let (algebra, budget, storage) = try setup()
        let identities = rows([[1, 1]])
        do {
            let trueRelation = try algebra.membership(rows: identities, query: [integer(1), integer(1)])
            guard case .member = trueRelation.certificate else { Issue.record("Expected exact membership"); return }
            try algebra.verify(rows: identities, query: [integer(1), integer(1)], certificate: trueRelation.certificate)
            let falseRelation = try algebra.membership(rows: identities, query: [integer(1), .zero])
            guard case .nonmember = falseRelation.certificate else { Issue.record("A model-local identity became a false global relation"); return }
            try algebra.verify(rows: identities, query: [integer(1), .zero], certificate: falseRelation.certificate)
            let body = try algebra.membership(rows: rows([[1, 1, 0]]), query: [.zero, .zero, .one])
            guard case .nonmember = body.certificate else { Issue.record("Unproved body/flow row was omitted"); return }
        }
        #expect(storage.live == 0)
        #expect(budget.statistics.workUnits > 0)
        #expect(budget.statistics.solveAttempts == 0)
        #expect(budget.statistics.newtonIterations == 0)
    }

    @Test func redundantRowsAndFractionalQueriesKeepOriginalCoefficientAxis() throws {
        let (algebra, _, _) = try setup()
        let matrix = rows([[2, 4], [-1, -2], [0, 0]])
        let query: [Scalar] = [.init(words: [1], denominatorPower: 1), .one]
        let result = try algebra.membership(rows: matrix, query: query)
        guard case .member(_, let coefficients) = result.certificate else { Issue.record("Dyadic query was refused"); return }
        #expect(coefficients.count == 3)
        try algebra.verify(rows: matrix, query: query, certificate: result.certificate)
    }

    @Test func completionHasAnExactNondyadicInverseAndDetectsForgedProducts() throws {
        let (algebra, _, storage) = try setup()
        let basis = rows([[3, 1]])
        do {
            let result = try algebra.completion(basis: basis)
            #expect(result.certificate.selectors == [1])
            #expect(result.certificate.scale == integer(3))
            #expect(result.certificate.inverseNumerators == [integer(1), integer(-1), .zero, integer(3)])
            try algebra.verify(basis: basis, certificate: result.certificate)
            let wrongSelector = Algebra.CompletionCertificate(selectors: [0],
                inverseNumerators: result.certificate.inverseNumerators, scale: result.certificate.scale)
            #expect(throws: Algebra.Failure.inconsistentCertificate) { try algebra.verify(basis: basis, certificate: wrongSelector) }
            var altered = result.certificate.inverseNumerators; altered[0] = integer(2)
            let wrongInverse = Algebra.CompletionCertificate(selectors: [1], inverseNumerators: altered, scale: integer(3))
            #expect(throws: Algebra.Failure.inconsistentCertificate) { try algebra.verify(basis: basis, certificate: wrongInverse) }
            let wrongScale = Algebra.CompletionCertificate(selectors: [1],
                inverseNumerators: result.certificate.inverseNumerators, scale: integer(-3))
            #expect(throws: Algebra.Failure.inconsistentCertificate) { try algebra.verify(basis: basis, certificate: wrongScale) }
        }
        #expect(storage.live == 0)
    }

    @Test func pivotSwapsDyadicRowsAndCompletionBoundaries() throws {
        let (algebra, _, _) = try setup()
        let dyadic = Algebra.Rows(rowCount: 1, columnCount: 2,
            values: [.zero, .init(negative: true, words: [3], denominatorPower: 2)])
        let completed = try algebra.completion(basis: dyadic)
        #expect(completed.certificate.selectors == [0])
        try algebra.verify(basis: dyadic, certificate: completed.certificate)
        let swapped = rows([[0, 2], [-3, 1]])
        let square = try algebra.completion(basis: swapped)
        #expect(square.certificate.selectors.isEmpty)
        try algebra.verify(basis: swapped, certificate: square.certificate)
        let rectangular = rows([[0, 1, 2], [3, 4, 5]])
        let three = try algebra.completion(basis: rectangular)
        #expect(three.certificate.selectors == [2])
        try algebra.verify(basis: rectangular, certificate: three.certificate)
        let empty = Algebra.Rows(rowCount: 0, columnCount: 3, values: [])
        let identity = try algebra.completion(basis: empty)
        #expect(identity.certificate.selectors == [0, 1, 2])
        try algebra.verify(basis: empty, certificate: identity.certificate)
        #expect(throws: Algebra.Failure.dependentBasis) { try algebra.completion(basis: rows([[1, 1], [2, 2]])) }
    }

    @Test func exactSeparatingAndMemberWitnessesCannotBeForged() throws {
        let (algebra, _, _) = try setup()
        let matrix = rows([[1, 1]])
        let falseMember = Algebra.MembershipCertificate.member(scale: .one, coefficients: [.one])
        #expect(throws: Algebra.Failure.inconsistentCertificate) {
            try algebra.verify(rows: matrix, query: [integer(2), integer(2)], certificate: falseMember)
        }
        let falseSeparator = Algebra.MembershipCertificate.nonmember(separator: [.one, .zero])
        #expect(throws: Algebra.Failure.inconsistentCertificate) {
            try algebra.verify(rows: matrix, query: [.one, .zero], certificate: falseSeparator)
        }
        let zeroScale = Algebra.MembershipCertificate.member(scale: .zero, coefficients: [.zero])
        #expect(throws: Algebra.Failure.inconsistentCertificate) {
            try algebra.verify(rows: matrix, query: [.one, .zero], certificate: zeroScale)
        }
    }

    @Test func hugeDyadicCancellationPreservesTheNonzeroTail() throws {
        let (algebra, _, storage) = try setup(policy: limits(bits: 20_000))
        var largeWords = [UInt64](repeating: 0, count: 65); largeWords[64] = 1
        var almostOneWords = largeWords; almostOneWords[0] = 1
        let large = Scalar(words: largeWords)
        let almostOne = Scalar(words: almostOneWords, denominatorPower: 4096)
        let matrix = Algebra.Rows(rowCount: 1, columnCount: 2, values: [large, .one])
        do {
            let result = try algebra.membership(rows: matrix, query: [large, almostOne])
            guard case .nonmember = result.certificate else { Issue.record("Exact dyadic tail was rounded away"); return }
            try algebra.verify(rows: matrix, query: [large, almostOne], certificate: result.certificate)
        }
        #expect(storage.live == 0)
        let (small, _, smallStorage) = try setup(policy: limits(bits: 4097))
        #expect(throws: Algebra.Failure.bitLimit) { try small.membership(rows: matrix, query: [large, almostOne]) }
        #expect(smallStorage.live == 0)
    }

    @Test func signedLimbCarryBorrowMultiplyAndCancellationAreExact() throws {
        let (algebra, _, storage) = try setup(policy: limits(bits: 256))
        do {
            let pool = try ExactLimbPool(slots: 8, metadataBytes: 0, limits: algebra.limits, control: algebra.control)
            let output = try algebra.control.reserveStorage(byteCount: 10_000)
            try pool.load(0, .init(words: [UInt64.max]), clearingPower: 0)
            try pool.one(1); try pool.add(2, 0, 1)
            #expect(try pool.export(2, lease: output) == Scalar(words: [0, 1]))
            try pool.add(3, 2, 1, subtract: true)
            #expect(try pool.export(3, lease: output) == Scalar(words: [UInt64.max]))
            try pool.multiply(4, 0, 0)
            #expect(try pool.export(4, lease: output) == Scalar(words: [1, UInt64.max - 1]))
            pool.negate(4); try pool.add(5, 4, 4, subtract: true)
            #expect(try pool.export(5, lease: output) == .zero)
            try pool.load(0, integer(-7), clearingPower: 0)
            try pool.load(1, integer(3), clearingPower: 0)
            try pool.add(2, 0, 1); try pool.multiply(3, 0, 1)
            #expect(try pool.export(2, lease: output) == integer(-4))
            #expect(try pool.export(3, lease: output) == integer(-21))
        }
        #expect(storage.live == 0)
    }

    @Test func smallSignedArithmeticMatchesIndependentMachineIntegers() throws {
        let (algebra, _, _) = try setup(policy: limits(bits: 128))
        let pool = try ExactLimbPool(slots: 4, metadataBytes: 0, limits: algebra.limits, control: algebra.control)
        let output = try algebra.control.reserveStorage(byteCount: 10_000)
        let values: ClosedRange<Int64> = -8...8
        for a in values { for b in values {
            try pool.load(0, integer(a), clearingPower: 0)
            try pool.load(1, integer(b), clearingPower: 0)
            try pool.add(2, 0, 1); try pool.multiply(3, 0, 1)
            #expect(try pool.export(2, lease: output) == integer(a + b))
            #expect(try pool.export(3, lease: output) == integer(a * b))
        }}
    }

    @Test func coldPoolInitializationAdmitsEveryParallelArrayBeforeAllocation() throws {
        let (algebra, budget, storage) = try setup(policy: limits(bits: 64), work: 16)
        let refusal = TransientExecutionError.limitExceeded(resource: "workUnits", limit: 16, requested: 24)
        #expect(throws: refusal) {
            try ExactLimbPool(slots: 8, metadataBytes: 0, limits: algebra.limits, control: algebra.control)
        }
        #expect(budget.statistics.workUnits == 0)
        #expect(storage.live == 0)
    }

    @Test func exportedLimbArrayAdmitsInitializationIndependentlyOfUnusedCredits() throws {
        let (algebra, budget, storage) = try setup(policy: limits(bits: 64), work: 265)
        do {
            let pool = try ExactLimbPool(slots: 3, metadataBytes: 0, limits: algebra.limits, control: algebra.control)
            try pool.load(0, .init(words: [7]), clearingPower: 0)
            let output = try algebra.control.reserveStorage(byteCount: 100)
            let used = budget.statistics.workUnits
            #expect(throws: TransientExecutionError.self) { try pool.export(0, lease: output) }
            #expect(budget.statistics.workUnits == used)
        }
        #expect(storage.live == 0)
    }

    @Test func malformedShapesScalarsAndMachineOverflowRefuse() throws {
        let (algebra, _, storage) = try setup()
        let invalid: [Scalar] = [.init(negative: true, words: []), .init(words: [0]),
            .init(words: [2], denominatorPower: 1), .init(words: [], denominatorPower: 1)]
        for value in invalid {
            #expect(throws: Algebra.Failure.invalidInput) {
                try algebra.membership(rows: .init(rowCount: 1, columnCount: 1, values: [value]), query: [.zero])
            }
        }
        #expect(throws: Algebra.Failure.invalidInput) {
            try algebra.membership(rows: .init(rowCount: 1, columnCount: 2, values: [.one]), query: [.one, .one])
        }
        let overflowing = Algebra.Limits(maximumRows: Int.max, maximumColumns: Int.max,
            maximumIntegerBits: 64, maximumWorkspaceBytes: Int.max, maximumResultBytes: Int.max)
        let (large, _, _) = try setup(policy: overflowing)
        #expect(throws: TransientExecutionError.self) {
            try large.membership(rows: .init(rowCount: Int.max, columnCount: 2, values: []), query: [.one, .one])
        }
        #expect(storage.live == 0)
    }

    @Test func bitWorkWorkspaceResultAndUpstreamRefusalsRefundWithoutReset() throws {
        let matrix = rows([[3, 1]])
        for policy in [limits(workspace: 1), limits(result: 1), limits(bits: 1)] {
            let (algebra, _, storage) = try setup(policy: policy)
            #expect(throws: Algebra.Failure.self) { try algebra.completion(basis: matrix) }
            #expect(storage.live == 0)
        }
        let (scarce, _, workStorage) = try setup(work: 10)
        #expect(throws: TransientExecutionError.self) { try scarce.membership(rows: matrix, query: [.one, .one]) }
        #expect(workStorage.live == 0)
        let storage = Storage(capacity: 1)
        let (refused, _, _) = try setup(storage: storage)
        #expect(throws: Storage.Refusal.self) { try refused.completion(basis: matrix) }
        #expect(storage.live == 0)
        let (algebra, budget, owner) = try setup()
        do { _ = try algebra.membership(rows: matrix, query: [.one, .one]) }
        let before = budget.statistics.workUnits
        do { _ = try algebra.membership(rows: matrix, query: [.one, .one]) }
        #expect(budget.statistics.workUnits > before)
        #expect(owner.live == 0)
        let (limited, shared, limitedStorage) = try setup(work: before * 2 - 1)
        do { _ = try limited.membership(rows: matrix, query: [.one, .one]) }
        let used = shared.statistics.workUnits
        #expect(throws: TransientExecutionError.self) { try limited.membership(rows: matrix, query: [.one, .one]) }
        #expect(shared.statistics.workUnits >= used)
        #expect(limitedStorage.live == 0)
    }

    @Test func cancellationAfterAdmissionAndDuringLimbMultiplicationRefund() throws {
        let token = CancellationToken(), storage = Storage()
        storage.cancelOnAdmission = token
        let (algebra, _, _) = try setup(token: token, storage: storage)
        #expect(throws: AnalysisError.self) { try algebra.completion(basis: rows([[3, 1]])) }
        #expect(storage.live == 0)
        let inFlight = CancellationToken()
        let (ordinary, budget, owner) = try setup(policy: limits(bits: 16_384), token: inFlight)
        let control = CancellingControl(base: ordinary.control, token: inFlight)
        do {
            let pool = try ExactLimbPool(slots: 4, metadataBytes: 0, limits: ordinary.limits, control: control)
            let operand = Scalar(words: [UInt64](repeating: .max, count: 100))
            try pool.load(0, operand, clearingPower: 0); try pool.load(1, operand, clearingPower: 0)
            control.arm()
            #expect(throws: AnalysisError.self) { try pool.multiply(2, 0, 1) }
            #expect(control.interrupted)
            #expect(budget.statistics.workUnits > 0)
        }
        #expect(owner.live == 0)
    }

    @Test func finalResultCopyOwnsTheReservationAndFreshInvocationRetries() throws {
        let (algebra, _, storage) = try setup()
        var retained: Algebra.CompletionResult?
        do {
            let result = try algebra.completion(basis: rows([[3, 1]]))
            retained = result
        }
        #expect(storage.live > 0)
        do {
            let held = try #require(retained)
            try algebra.verify(basis: rows([[3, 1]]), certificate: held.certificate)
            retained = nil
            withExtendedLifetime(held) { #expect(storage.live > 0) }
        }
        #expect(storage.live == 0)
        let (fresh, _, _) = try setup()
        _ = try fresh.completion(basis: rows([[3, 1]]))
    }

    @Test func extractedCertificateComponentsRetainTheirBackingAdmission() throws {
        let (algebra, _, storage) = try setup()
        var selectors: ExactRowBuffer<Int>?
        var words: ExactRowBuffer<UInt64>?
        do {
            let result = try algebra.completion(basis: rows([[3, 1]]))
            selectors = result.certificate.selectors; words = result.certificate.scale.words
        }
        withExtendedLifetime(selectors) { #expect(storage.live > 0) }
        selectors = nil
        withExtendedLifetime(words) { #expect(storage.live > 0) }
        words = nil
        #expect(storage.live == 0)
    }

    @Test func cancelledTaskCannotPublishAnExactCertificate() async throws {
        let (algebra, _, storage) = try setup()
        let matrix = rows([[3, 1]])
        let refused = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try algebra.completion(basis: matrix); return false }
            catch AnalysisError.cancelled { return true }
            catch { return false }
        }.value
        #expect(refused)
        #expect(storage.live == 0)
    }

    private final class Storage: AnalysisResultStorageAccounting, Sendable {
        enum Refusal: Error { case capacity }
        private struct State { var live = 0; var cancellation: CancellationToken? }
        private let state = Mutex(State())
        let capacity: Int
        init(capacity: Int = 100_000_000) { self.capacity = capacity }
        var live: Int { state.withLock { $0.live } }
        var cancelOnAdmission: CancellationToken? {
            get { state.withLock { $0.cancellation } }
            set { state.withLock { $0.cancellation = newValue } }
        }
        func reserveResultScalars(_ capacity: Int) throws { Issue.record("Exact limbs were counted as Double scalars") }
        func reserveTemporaryBytes(_ bytes: UInt64) throws -> any Sendable {
            let count = try #require(Int(exactly: bytes))
            let token = try state.withLock { value in
                guard count <= capacity - value.live else { throw Refusal.capacity }
                value.live += count; return value.cancellation
            }
            let lease = Lease(owner: self, count: count)
            token?.cancel()
            return lease
        }
        private final class Lease: Sendable {
            let owner: Storage
            let count: Int
            init(owner: Storage, count: Int) { self.owner = owner; self.count = count }
            deinit { owner.state.withLock { $0.live -= count } }
        }
    }
    private final class CancellingControl: LinearSolverExecutionControlling, Sendable {
        let base: any LinearSolverExecutionControlling
        let token: CancellationToken
        private let remaining = Mutex<Int?>(nil)
        var interrupted: Bool { token.isCancelled }
        init(base: any LinearSolverExecutionControlling, token: CancellationToken) { self.base = base; self.token = token }
        func arm() { remaining.withLock { $0 = 2 } }
        func checkpoint(workUnits: Int) throws {
            try base.checkpoint(workUnits: workUnits)
            let interrupt = remaining.withLock { value -> Bool in
                guard let current = value, workUnits > 0 else { return false }
                value = current - 1; return current == 1
            }
            if interrupt { token.cancel(); try base.checkpoint(workUnits: 0) }
        }
        func reserveStorage(byteCount: Int) throws -> any Sendable { try base.reserveStorage(byteCount: byteCount) }
    }
}
