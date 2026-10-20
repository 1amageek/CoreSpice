import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import Synchronization
import Testing
@testable import CoreSpiceAnalysis

@Suite("Conditional uniform Picard slab", .timeLimit(.minutes(1)))
struct ValidatedPicardSlabTests {
    private typealias Checker = ValidatedPicardSlab
    private typealias E = CompensatedEnclosure
    private typealias V = CompensatedValue
    private func point(_ value: Double, low: Double = 0) throws -> V { try .init(high: value, low: low) }
    private func enclosure(_ value: Double, radius: Double = 0) throws -> E {
        try .init(center: point(value), radius: radius)
    }
    private func limits(dimension: Int = 1024, bytes: Int = 1_048_576) -> Checker.Limits {
        .init(maximumDimension: dimension, maximumResultBytes: bytes)
    }
    private func check(lower: [V], upper: [V], initial: [E], field: [E], duration: V,
        lipschitz: Double = 0, control: Control = .init(), limits selected: Checker.Limits? = nil,
        cancellation: CancellationToken = .init()) throws -> Checker.Result {
        try Checker.certify(lower: lower.span, upper: upper.span, initial: initial.span, field: field.span,
            duration: duration, lipschitzUpperBound: lipschitz, limits: selected ?? limits(),
            control: control, cancellation: cancellation)
    }
    private func scalar(lower: Double = 0, upper: Double = 1, initial: E? = nil, field: E? = nil,
        duration: Double = 0.25, lipschitz: Double = 0, control: Control = .init(),
        limits: Checker.Limits? = nil, cancellation: CancellationToken = .init()) throws -> Checker.Result {
        try check(lower: [point(lower)], upper: [point(upper)], initial: [initial ?? enclosure(0.25)],
            field: [field ?? enclosure(1.5, radius: 0.5)], duration: point(duration),
            lipschitz: lipschitz, control: control, limits: limits, cancellation: cancellation)
    }
    private func bounds(_ value: E) -> ClosedRange<Double> {
        let b = value.center.bounds
        return value.radius == 0 ? b.lower...b.upper : (b.lower - value.radius).nextDown...(b.upper + value.radius).nextUp
    }

    @Test func exactDyadicPositiveAndNegativeFieldsCoverTheWholeConvexSlab() throws {
        let positive = try scalar(lipschitz: 2)
        let p = bounds(try positive.endpoint(at: 0))
        #expect(p.lowerBound <= 0.5 && p.upperBound >= 0.75)
        #expect(p.lowerBound > 0.49 && p.upperBound < 0.76)
        #expect(positive.dimension == 1 && positive.contractionUpperBound >= 0.5 && positive.contractionUpperBound < 0.51)
        let negative = try scalar(initial: enclosure(0.75), field: enclosure(-1.5, radius: 0.5), lipschitz: 2)
        let n = bounds(try negative.endpoint(at: 0))
        #expect(n.lowerBound <= 0.25 && n.upperBound >= 0.5)
        #expect(n.lowerBound > 0.24 && n.upperBound < 0.51)
        // Convex hull with the initial set also covers tau=0 and every intermediate time.
        let initialSet = try scalar(initial: enclosure(0.5, radius: 0.125), field: enclosure(1), duration: 0.125)
        let i = bounds(try initialSet.endpoint(at: 0))
        #expect(i.lowerBound <= 0.5 && i.upperBound >= 0.75)
    }

    @Test func initialAndEndpointCounterexamplesRefuseAtTheirActualStage() throws {
        let initialControl = Control()
        // Endpoint=1 is inside Q, but initial=2 is outside: endpoint-only acceptance is false.
        #expect(throws: Checker.Failure.selfMapUncertified) {
            try scalar(initial: enclosure(2), field: enclosure(-1), duration: 1, control: initialControl)
        }
        #expect(initialControl.reservations == 0 && initialControl.live == 0)
        let endControl = Control()
        #expect(throws: Checker.Failure.selfMapUncertified) {
            try scalar(initial: enclosure(0.5), field: enclosure(-1), duration: 1, control: endControl)
        }
        #expect(endControl.reservations == 1 && endControl.live == 0)
        #expect(throws: Checker.Failure.selfMapUncertified) {
            try scalar(lower: -0.5, upper: 0.5, initial: enclosure(0), field: enclosure(0, radius: 1), duration: 1)
        }
    }

    @Test func strictUnitContractionBoundaryRefusesDespiteSelfMapContainment() throws {
        for lipschitz in [1.0, 2.0] {
            let control = Control()
            #expect(throws: Checker.Failure.contractionUncertified) {
                try scalar(lower: -1, upper: 1, initial: enclosure(0), field: enclosure(0),
                    duration: 1, lipschitz: lipschitz, control: control)
            }
            #expect(control.reservations == 0 && control.live == 0)
        }
        let zero = try scalar(lower: 0, upper: 0, initial: enclosure(0), field: enclosure(0), duration: 1)
        #expect(zero.contractionUpperBound == 0)
        #expect(try zero.endpoint(at: 0) == enclosure(0))
    }

    @Test func exactLowComponentsSurviveInitialContainmentAndDurationMultiplication() throws {
        let small = 0x1p-60, control = Control()
        #expect(throws: Checker.Failure.selfMapUncertified) {
            try check(lower: [point(1, low: -small)], upper: [point(1)],
                initial: [E(center: point(1, low: small))], field: [enclosure(0)], duration: point(1), control: control)
        }
        #expect(control.reservations == 0)
        let duration = try point(1, low: -small)
        let result = try check(lower: [point(-1)], upper: [point(2)], initial: [enclosure(0)],
            field: [enclosure(1)], duration: duration)
        #expect(result.duration == duration)
        let end = try result.endpoint(at: 0)
        #expect(end.center.high == 1 && end.center.low == -small)
    }

    @Test func emptyMalformedAndCapacityInputsRefuseBeforeAllocation() throws {
        let control = Control(), z = try point(0), one = try point(1), e = try enclosure(0)
        let malformed: [([V], [V], [E], [E])] = [([], [], [], []), ([one], [z], [e], [e]),
            ([z], [], [e], [e]), ([z], [one], [], [e]), ([z], [one], [e], [])]
        for (lo, hi, initial, field) in malformed {
            #expect(throws: Checker.Failure.invalidInput) {
                try check(lower: lo, upper: hi, initial: initial, field: field, duration: one, control: control)
            }
        }
        for duration in [0.0, -1.0] {
            #expect(throws: Checker.Failure.invalidInput) { try scalar(duration: duration, control: control) }
        }
        #expect(throws: Checker.Failure.invalidInput) { try scalar(lipschitz: -1, control: control) }
        #expect(throws: Checker.Failure.invalidInput) { try scalar(control: control, limits: limits(dimension: 0)) }
        #expect(throws: Checker.Failure.invalidInput) { try scalar(control: control, limits: limits(bytes: -1)) }
        let bytes = try Checker.resultByteCount(dimension: 1)
        #expect(throws: Checker.Failure.resultLimit) { try scalar(control: control, limits: limits(bytes: bytes - 1)) }
        #expect(throws: TransientExecutionError.self) { try Checker.resultByteCount(dimension: Int.max) }
        #expect(control.reservations == 0 && control.live == 0)
    }

    @Test func nonfiniteBoundsCannotBecomeFiniteConditionalFacts() throws {
        let control = Control()
        for lipschitz in [Double.nan, Double.infinity] {
            #expect(throws: Checker.Failure.nonFiniteInput) { try scalar(lipschitz: lipschitz, control: control) }
        }
        let unbounded = try enclosure(.greatestFiniteMagnitude, radius: .greatestFiniteMagnitude)
        #expect(throws: Checker.Failure.nonFiniteInput) { try scalar(initial: unbounded, control: control) }
        #expect(throws: Checker.Failure.nonFiniteInput) { try scalar(field: unbounded, control: control) }
        let projectedInfinite = try point(.greatestFiniteMagnitude, low: 1)
        #expect(throws: Checker.Failure.nonFiniteInput) {
            try check(lower: [point(0)], upper: [projectedInfinite], initial: [enclosure(0)],
                field: [enclosure(0)], duration: point(1), control: control)
        }
        #expect(control.reservations == 0 && control.live == 0)
    }

    @Test func positiveUnderflowContractionProductIsNotSilentlyZero() throws {
        let tiny = Double.leastNonzeroMagnitude
        let result = try scalar(lower: -1, upper: 1, initial: enclosure(0), field: enclosure(0),
            duration: tiny, lipschitz: tiny)
        #expect(result.contractionUpperBound > 0 && result.contractionUpperBound < 1)
    }

    @Test func arithmeticOverflowReleasesTheAdmittedResultInsteadOfPublishingPartialEndpoints() throws {
        let control = Control()
        #expect(throws: NumericalStateError.arithmeticOverflow) {
            try scalar(lower: -1, upper: 1, initial: enclosure(0), field: enclosure(.greatestFiniteMagnitude),
                duration: 2, control: control)
        }
        #expect(control.reservations == 1 && control.live == 0)
        #expect(throws: NumericalStateError.arithmeticOverflow) {
            try scalar(lower: -1, upper: 1, initial: enclosure(0), field: enclosure(0),
                duration: .greatestFiniteMagnitude, lipschitz: 2)
        }
    }

    @Test func originalWorkCeilingIsCumulativeAndFailureRefundsOnlyStorage() throws {
        let control = Control(maximumWork: 14)
        do { _ = try scalar(control: control) }
        #expect(control.work == 14 && control.reservations == 1 && control.live == 0)
        #expect(throws: Cause.work) { try scalar(control: control) }
        #expect(control.work == 14 && control.reservations == 1 && control.live == 0)
        let interrupted = Control(maximumWork: 8)
        #expect(throws: Cause.work) { try scalar(control: interrupted) }
        #expect(interrupted.work == 8 && interrupted.reservations == 1 && interrupted.live == 0)
    }

    @Test func preMidAndTaskCancellationPublishNoResultAndReleaseItsLease() async throws {
        let cancelled = CancellationToken(); cancelled.cancel()
        let pre = Control()
        do { _ = try scalar(control: pre, cancellation: cancelled); Issue.record("Cancelled call published") }
        catch AnalysisError.cancelled {}
        #expect(pre.work == 0 && pre.reservations == 0)
        let token = CancellationToken(), mid = Control(cancelAtWork: 9, token: token)
        do { _ = try scalar(control: mid, cancellation: token); Issue.record("Interrupted call published") }
        catch AnalysisError.cancelled {}
        #expect(mid.work == 9 && mid.reservations == 1 && mid.live == 0)
        let taskControl = Control()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try scalar(control: taskControl)
        }
        do { _ = try await task.value; Issue.record("Cancelled task published") }
        catch AnalysisError.cancelled {}
        #expect(taskControl.work == 0 && taskControl.live == 0 && taskControl.reservations == 0)
    }

    @Test func storageFailureAndFinalCopyRetainOnlyTheInitializedEndpointPayload() throws {
        let failed = Control(failReservation: true)
        #expect(throws: Cause.storage) { try scalar(control: failed) }
        #expect(failed.reservations == 1 && failed.live == 0)
        let control = Control(), bytes = try Checker.resultByteCount(dimension: 1)
        var copy: Checker.Result?
        do {
            let result = try scalar(control: control, limits: limits(bytes: bytes))
            copy = result
            #expect(control.live == bytes && control.peak == bytes && control.reservations == 1)
            #expect(throws: Checker.Failure.invalidInput) { try result.endpoint(at: 1) }
            #expect(throws: Checker.Failure.invalidInput) { try result.endpoint(at: -1) }
        }
        #expect(try #require(copy).dimension == 1 && control.live == bytes)
        copy = nil
        #expect(control.live == 0)
    }

    @Test func borrowedVectorInputsAndOneLinearResultAllocationRemainOwnedByTheCaller() throws {
        let n = 128, control = Control(maximumWork: 2_000)
        let lower = try [V](repeating: point(0), count: n), upper = try [V](repeating: point(1), count: n)
        let initial = try [E](repeating: enclosure(0.25), count: n), field = try [E](repeating: enclosure(1.5, radius: 0.5), count: n)
        do {
            let result = try check(lower: lower, upper: upper, initial: initial, field: field, duration: point(0.25),
                lipschitz: 2, control: control)
            #expect(result.dimension == n && control.reservations == 1)
            #expect(control.live == (try Checker.resultByteCount(dimension: n)))
            #expect(control.peak == control.live && control.work == 12 * n + 2)
            let expectedInitial = try enclosure(0.25), expectedField = try enclosure(1.5, radius: 0.5)
            let expectedLower = try point(0), expectedUpper = try point(1)
            for row in 0..<n {
                let image = bounds(try result.endpoint(at: row))
                #expect(image.lowerBound <= 0.5 && image.upperBound >= 0.75)
                #expect(initial[row] == expectedInitial && field[row] == expectedField)
                #expect(lower[row] == expectedLower && upper[row] == expectedUpper)
            }
        }
        #expect(control.live == 0)
    }

    private enum Cause: Error { case work, storage }
    private final class Control: LinearSolverExecutionControlling {
        private struct State { var work = 0; var live = 0; var peak = 0; var reservations = 0 }
        private let state = Mutex(State())
        private let maximumWork: Int
        private let failReservation: Bool
        private let cancelAtWork: Int?
        private let token: CancellationToken?
        init(maximumWork: Int = 1_000_000, failReservation: Bool = false,
            cancelAtWork: Int? = nil, token: CancellationToken? = nil) {
            self.maximumWork = maximumWork; self.failReservation = failReservation
            self.cancelAtWork = cancelAtWork; self.token = token
        }
        var work: Int { state.withLock { $0.work } }
        var live: Int { state.withLock { $0.live } }
        var peak: Int { state.withLock { $0.peak } }
        var reservations: Int { state.withLock { $0.reservations } }
        func checkpoint(workUnits: Int) throws {
            let cancel = try state.withLock { value in
                guard workUnits >= 0, workUnits <= maximumWork - value.work else { throw Cause.work }
                value.work += workUnits
                return cancelAtWork.map { value.work >= $0 } ?? false
            }
            // The cancellation callback remains outside the accounting mutex.
            if cancel { token?.cancel() }
        }
        func reserveStorage(byteCount: Int) throws -> any Sendable {
            try state.withLock { value in
                value.reservations += 1
                guard !failReservation else { throw Cause.storage }
                value.live += byteCount; value.peak = max(value.peak, value.live)
            }
            return Lease(owner: self, bytes: byteCount)
        }
        private final class Lease: Sendable {
            let owner: Control
            let bytes: Int
            init(owner: Control, bytes: Int) { self.owner = owner; self.bytes = bytes }
            deinit { owner.state.withLock { $0.live -= bytes } }
        }
    }
}
