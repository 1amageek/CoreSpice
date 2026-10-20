import CoreSpiceDevices
import CoreSpiceEvent
import Synchronization
import Testing
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile

@Suite("Validated sparse parametric roots", .timeLimit(.minutes(1)))
struct ValidatedParametricRootTests {
    private typealias Checker = ValidatedParametricRoot
    private typealias E = CompensatedEnclosure
    private typealias V = CompensatedValue

    private func point(_ value: Double, low: Double = 0) throws -> V { try V(high: value, low: low) }
    private func enclosure(_ value: Double, radius: Double = 0) throws -> E {
        try E(center: point(value), radius: radius)
    }
    private func diagonal(_ n: Int) throws -> SparseStructure {
        try .init(dimension: n, rowPointers: Array(0...n), columnIndices: Array(0..<n))
    }
    private func limits(_ n: Int, jacobian: Int, inverse: Int,
        workspace: Int = 10_000_000, result: Int = 10_000_000) -> Checker.Limits {
        .init(maximumDimension: n, maximumJacobianNonzeros: jacobian,
            maximumPreconditionerNonzeros: inverse, maximumWorkspaceBytes: workspace, maximumResultBytes: result)
    }
    private func check(lower: [V], upper: [V], center: [V], residual: [E],
        jacobian: SparseStructure, values: [E], inverse: SparseStructure, coefficients: [Double],
        control: any LinearSolverExecutionControlling = Control(),
        limits selected: Checker.Limits? = nil) throws -> Checker.Result {
        try Checker.certify(lower: lower.span, upper: upper.span, center: center.span,
            centerResidual: residual.span, jacobian: jacobian, jacobianValues: values.span,
            preconditioner: inverse, preconditionerValues: coefficients.span,
            limits: selected ?? limits(jacobian.dimension, jacobian: values.count, inverse: coefficients.count),
            control: control)
    }
    private func scalar(lower: Double = -1, upper: Double = 1, center: Double = 0,
        residual: E, jacobian: E, inverse: Double = 1,
        control: any LinearSolverExecutionControlling = Control(),
        limits: Checker.Limits? = nil) throws -> Checker.Result {
        let pattern = try diagonal(1)
        return try check(lower: [point(lower)], upper: [point(upper)], center: [point(center)], residual: [residual],
            jacobian: pattern, values: [jacobian], inverse: pattern, coefficients: [inverse], control: control, limits: limits)
    }
    private func bounds(_ value: E) -> (lower: Double, upper: Double) {
        let center = value.center.bounds
        return value.radius == 0 ? center : ((center.lower - value.radius).nextDown, (center.upper + value.radius).nextUp)
    }

    @Test func actualChartShapeHasUniformChargeAndAlgebraicRootsDespiteSingularChargeMatrix() throws {
        // H=(2*d-q,(x-phi)/4), q in [.75,1.25], phi in [-.25,.25].
        let pattern = try diagonal(2)
        let result = try check(lower: [point(0.25), point(-0.5)], upper: [point(0.75), point(0.5)],
            center: [point(0.5), point(0)], residual: [enclosure(0, radius: 0.25), enclosure(0, radius: 0.0625)],
            jacobian: pattern, values: [enclosure(2), enclosure(0.25)], inverse: pattern, coefficients: [0.5, 4])
        #expect(result.dimension == 2)
        #expect(result.normUpperBound < 0x1p-40)
        let charge = bounds(try result.image(at: 0)), algebraic = bounds(try result.image(at: 1))
        #expect(charge.lower <= 0.375 && charge.upper >= 0.625)
        #expect(charge.lower > 0.25 && charge.upper < 0.75)
        #expect(algebraic.lower <= -0.25 && algebraic.upper >= 0.25)
        #expect(algebraic.lower > -0.5 && algebraic.upper < 0.5)
    }

    @Test func nonCenteredAsymmetricBoxUsesOriginalEndpointsAndDisplacement() throws {
        // Exact K=[1.25,2.25], q=1/2; z0 is not the midpoint of [1,3].
        let result = try scalar(lower: 1, upper: 3, center: 1.25,
            residual: enclosure(-0.25), jacobian: enclosure(1), inverse: 0.5)
        let image = bounds(try result.image(at: 0))
        #expect(image.lower <= 1.25 && image.upper >= 2.25)
        #expect(image.lower > 1 && image.upper < 3)
        #expect(result.normUpperBound >= 0.5 && result.normUpperBound < 0.5 + 0x1p-45)
        // Root .75 is outside [1,3], although |.75-z0| is less than half its width.
        #expect(throws: Checker.Failure.uncertified) {
            try scalar(lower: 1, upper: 3, center: 1.25, residual: enclosure(0.5), jacobian: enclosure(1))
        }
    }

    @Test func strictEndpointTouchAndUnitContractionNeverSucceed() throws {
        #expect(throws: Checker.Failure.uncertified) {
            try scalar(lower: 0, upper: 1, center: 0.5, residual: enclosure(0.5), jacobian: enclosure(1))
        }
        #expect(throws: Checker.Failure.uncertified) {
            try scalar(residual: enclosure(0), jacobian: enclosure(2))
        }
    }

    @Test func parameterRangeCannotBeReplacedByCenterOnlyResidual() throws {
        // H=z-p. A common Jacobian does not make a wide parameter family admissible.
        let result = try scalar(residual: enclosure(0, radius: 0.5), jacobian: enclosure(1))
        let image = bounds(try result.image(at: 0))
        #expect(image.lower <= -0.5 && image.upper >= 0.5)
        #expect(throws: Checker.Failure.uncertified) {
            try scalar(residual: enclosure(0, radius: 2), jacobian: enclosure(1))
        }
    }

    @Test func nonlinearParameterFamilyUsesWholeSpatialJacobian() throws {
        // H=z^2-p, z0=1.5, p in [2,2.5], J([1,2])=[2,4].
        let result = try scalar(lower: 1, upper: 2, center: 1.5,
            residual: enclosure(0, radius: 0.25), jacobian: enclosure(3, radius: 1), inverse: 1.0 / 3.0)
        let image = bounds(try result.image(at: 0))
        #expect(image.lower <= 1.25 && image.upper >= 1.75)
        #expect(image.lower > 1 && image.upper < 2)
        #expect(result.normUpperBound >= 1.0 / 3.0 && result.normUpperBound < 0.34)
        #expect(throws: Checker.Failure.uncertified) {
            try scalar(residual: enclosure(0), jacobian: enclosure(1, radius: 1))
        }
    }

    @Test func singularPreconditionerCannotPublishAParametricRoot() throws {
        let pattern = try diagonal(2)
        #expect(throws: Checker.Failure.uncertified) {
            try check(lower: [point(-1), point(-1)], upper: [point(1), point(1)], center: [point(0), point(0)],
                residual: [enclosure(0), enclosure(0)], jacobian: pattern, values: [enclosure(1), enclosure(1)],
                inverse: pattern, coefficients: [1, 0])
        }
    }

    @Test func noncommutingSparseProductAndCancellationUseYTimesJ() throws {
        let pattern = try SparseStructure(dimension: 2, rowPointers: [0, 2, 3], columnIndices: [0, 1, 1])
        let values = try [2.0, 1, 1].map { try enclosure($0) }
        let coefficients = [0.5, -0.25, 1.0]
        let result = try check(lower: [point(-1), point(-1)], upper: [point(1), point(1)], center: [point(0), point(0)],
            residual: [enclosure(0), enclosure(0)], jacobian: pattern, values: values,
            inverse: pattern, coefficients: coefficients)
        // I-YJ=[0,-1/4;0,0]; the reversed product has norm 1/2.
        #expect(result.normUpperBound >= 0.25 && result.normUpperBound < 0.25 + 0x1p-45)
        let first = bounds(try result.image(at: 0))
        #expect(first.lower <= -0.25 && first.upper >= 0.25)
        #expect(values == [try enclosure(2), try enclosure(1), try enclosure(1)])
        #expect(coefficients == [0.5, -0.25, 1])
    }

    @Test func exactLowComponentsSurviveStrictGapCancellationAtLargeOffset() throws {
        let pattern = try diagonal(1), small = 0x1p-60
        let result = try check(lower: [point(1, low: -small)], upper: [point(1, low: small)],
            center: [point(1)], residual: [enclosure(0)], jacobian: pattern, values: [enclosure(1)],
            inverse: pattern, coefficients: [1])
        let image = try result.image(at: 0)
        #expect(image.center.high == 1)
        #expect(image.radius < small)
        #expect(throws: Checker.Failure.invalidInput) {
            try check(lower: [point(1, low: small)], upper: [point(1, low: small)], center: [point(1, low: small)],
                residual: [enclosure(0)], jacobian: pattern, values: [enclosure(1)], inverse: pattern, coefficients: [1])
        }
    }

    @Test func gradualUnderflowRetainsTheTinyRootAndOverflowRefuses() throws {
        let result = try scalar(residual: enclosure(-Double.leastNonzeroMagnitude), jacobian: enclosure(1))
        let image = bounds(try result.image(at: 0))
        #expect(image.lower <= Double.leastNonzeroMagnitude && image.upper >= Double.leastNonzeroMagnitude)
        let control = Control()
        #expect(throws: NumericalStateError.self) {
            try scalar(residual: enclosure(Double.greatestFiniteMagnitude), jacobian: enclosure(0.5), inverse: 2, control: control)
        }
        #expect(control.live == 0)
    }

    @Test func completeInputShapesBoxesAndCanonicalPatternsAreRequired() throws {
        let pattern = try diagonal(1)
        let malformed = SparseStructure(uncheckedDimension: 1, rowPointers: [0, 2], columnIndices: [0])
        #expect(throws: Checker.Failure.invalidCSR) {
            try check(lower: [point(-1)], upper: [point(1)], center: [point(0)], residual: [enclosure(0)],
                jacobian: malformed, values: [enclosure(1)], inverse: pattern, coefficients: [1])
        }
        for (lo, hi, center) in [(1.0, -1.0, 0.0), (-1.0, 1.0, 2.0), (0.0, 0.0, 0.0)] {
            #expect(throws: Checker.Failure.invalidInput) {
                try scalar(lower: lo, upper: hi, center: center, residual: enclosure(0), jacobian: enclosure(1))
            }
        }
        #expect(throws: Checker.Failure.invalidInput) {
            try check(lower: [], upper: [], center: [], residual: [], jacobian: pattern,
                values: [enclosure(1)], inverse: pattern, coefficients: [1])
        }
        let empty = try diagonal(0)
        #expect(throws: Checker.Failure.invalidInput) {
            try check(lower: [], upper: [], center: [], residual: [], jacobian: empty,
                values: [], inverse: empty, coefficients: [])
        }
        #expect(throws: Checker.Failure.nonFiniteInput) {
            try scalar(residual: enclosure(0), jacobian: enclosure(1), inverse: .nan)
        }
        #expect(throws: Checker.Failure.invalidInput) {
            try check(lower: [point(-1)], upper: [point(1)], center: [point(0)], residual: [enclosure(0)],
                jacobian: pattern, values: [], inverse: pattern, coefficients: [1])
        }
        #expect(throws: Checker.Failure.nonFiniteInput) {
            try scalar(residual: enclosure(Double.greatestFiniteMagnitude, radius: Double.greatestFiniteMagnitude),
                jacobian: enclosure(1))
        }
    }

    @Test func checkedCapacitiesAndExplicitByteCeilingsRefuseBeforeAllocation() throws {
        #expect(throws: TransientExecutionError.self) { try Checker.workspaceByteCount(dimension: Int.max) }
        #expect(throws: TransientExecutionError.self) { try Checker.resultByteCount(dimension: Int.max) }
        let control = Control()
        #expect(throws: Checker.Failure.workspaceLimit) {
            try scalar(residual: enclosure(0), jacobian: enclosure(1), control: control,
                limits: limits(1, jacobian: 1, inverse: 1, workspace: 1))
        }
        #expect(throws: Checker.Failure.resultLimit) {
            try scalar(residual: enclosure(0), jacobian: enclosure(1), control: control,
                limits: limits(1, jacobian: 1, inverse: 1, result: 1))
        }
        #expect(control.reservations == 0)
    }

    @Test func sharedPreSpentWorkCannotResetAcrossCallsOrPublishPartialImage() throws {
        let probe = Control()
        _ = try scalar(residual: enclosure(0), jacobian: enclosure(1), control: probe)
        let perCall = probe.work
        let control = Control(maximumWork: 7 + 2 * perCall - 1)
        try control.checkpoint(workUnits: 7)
        do {
            let result = try scalar(residual: enclosure(0), jacobian: enclosure(1), control: control)
            let retained = control.live
            do {
                _ = try scalar(residual: enclosure(0), jacobian: enclosure(1), control: control)
                Issue.record("Second root check reset the shared work budget")
            } catch Cause.work {}
            #expect(control.work <= 7 + 2 * perCall - 1)
            #expect(control.live == retained)
            withExtendedLifetime(result) {}
        }
        #expect(control.live == 0)
        let initRefusal = Control(maximumWork: 0)
        #expect(throws: Cause.work) { try scalar(residual: enclosure(0), jacobian: enclosure(1), control: initRefusal) }
        #expect(initRefusal.live == 0)
    }

    @Test func structuralZeroFillInProductsCannotEscapeTheSharedWorkCeiling() throws {
        let n = 8
        let pattern = try SparseStructure(dimension: n, rowPointers: (0...n).map { $0 * n },
            columnIndices: (0..<(n * n)).map { $0 % n })
        // Both numerical matrices are I, with all structural off-diagonal zero entries retained.
        // The 512 structural product candidates alone exceed this explicit caller allowance.
        let coefficients = (0..<(n * n)).map { $0 / n == $0 % n ? 1.0 : 0.0 }
        let values = try coefficients.map { try enclosure($0) }
        let control = Control(maximumWork: 400)
        #expect(throws: Cause.work) {
            try check(lower: [V](repeating: point(-1), count: n), upper: [V](repeating: point(1), count: n),
                center: [V](repeating: .zero, count: n), residual: [E](repeating: enclosure(0), count: n),
                jacobian: pattern, values: values, inverse: pattern, coefficients: coefficients, control: control)
        }
        #expect(control.reservations == 3)
        #expect(control.work == 400)
        #expect(control.live == 0)
    }

    @Test func everyAdmissionFailureAndCancellationRefundsWithoutSuccess() throws {
        for index in 1...3 {
            let failure = Control(failReservation: index)
            #expect(throws: Cause.storage) { try scalar(residual: enclosure(0), jacobian: enclosure(1), control: failure) }
            #expect(failure.live == 0)
            let cancellation = Control(cancelReservation: index)
            #expect(throws: Cause.cancelled) { try scalar(residual: enclosure(0), jacobian: enclosure(1), control: cancellation) }
            #expect(cancellation.live == 0)
        }
        let cancelled = Control()
        cancelled.token.cancel()
        #expect(throws: Cause.cancelled) { try scalar(residual: enclosure(0), jacobian: enclosure(1), control: cancelled) }
        let failed = Control(failCheckpoint: true)
        #expect(throws: Cause.checkpoint) { try scalar(residual: enclosure(0), jacobian: enclosure(1), control: failed) }
    }

    @Test func copiedResultRetainsOnlyAdmittedImageUntilItsFinalRelease() throws {
        let control = Control()
        var copy: Checker.Result?
        do {
            let result = try scalar(residual: enclosure(0), jacobian: enclosure(1), control: control)
            copy = result
            #expect(control.live == (try Checker.resultByteCount(dimension: 1)))
            #expect(throws: Checker.Failure.invalidInput) { try result.image(at: 1) }
        }
        #expect(control.live == (try Checker.resultByteCount(dimension: 1)))
        #expect(try #require(copy).dimension == 1)
        copy = nil
        #expect(control.live == 0)
    }

    @Test func tenThousandSparseRowsHaveLinearManagedPayloadAndBoundedProducts() throws {
        let n = 10_000, pattern = try diagonal(n), control = Control(maximumWork: 1_000_000)
        let lower = try [V](repeating: point(-1), count: n)
        let upper = try [V](repeating: point(1), count: n)
        let center = [V](repeating: .zero, count: n)
        let residual = try [E](repeating: enclosure(0), count: n)
        let values = try [E](repeating: enclosure(2), count: n)
        let coefficients = [Double](repeating: 0.5, count: n)
        do {
            let result = try check(lower: lower, upper: upper, center: center, residual: residual,
                jacobian: pattern, values: values, inverse: pattern, coefficients: coefficients, control: control)
            #expect(result.dimension == n)
            #expect(result.normUpperBound < 0x1p-40)
            #expect(control.peak == (try Checker.workspaceByteCount(dimension: n) + Checker.resultByteCount(dimension: n)))
            #expect(control.work < 1_000_000)
            #expect(control.live == (try Checker.resultByteCount(dimension: n)))
        }
        #expect(control.live == 0)
    }

    private enum Cause: Error, Equatable { case work, storage, cancelled, checkpoint }
    private final class Control: LinearSolverExecutionControlling {
        private struct State { var work = 0; var live = 0; var peak = 0; var reservations = 0 }
        private let state = Mutex(State())
        let token = CancellationToken()
        let maximumWork: Int
        let failReservation: Int?
        let cancelReservation: Int?
        let failCheckpoint: Bool
        init(maximumWork: Int = 10_000_000, failReservation: Int? = nil,
            cancelReservation: Int? = nil, failCheckpoint: Bool = false) {
            self.maximumWork = maximumWork; self.failReservation = failReservation
            self.cancelReservation = cancelReservation; self.failCheckpoint = failCheckpoint
        }
        var work: Int { state.withLock { $0.work } }
        var live: Int { state.withLock { $0.live } }
        var peak: Int { state.withLock { $0.peak } }
        var reservations: Int { state.withLock { $0.reservations } }
        func checkpoint(workUnits: Int) throws {
            if failCheckpoint { throw Cause.checkpoint }
            guard !token.isCancelled, !Task.isCancelled else { throw Cause.cancelled }
            try state.withLock { value in
                guard workUnits >= 0, workUnits <= maximumWork - value.work else { throw Cause.work }
                value.work += workUnits
            }
        }
        func reserveStorage(byteCount: Int) throws -> any Sendable {
            try checkpoint(workUnits: 0)
            let index = try state.withLock { value in
                value.reservations += 1
                if value.reservations == failReservation { throw Cause.storage }
                guard byteCount >= 0, byteCount <= Int.max - value.live else { throw Cause.storage }
                value.live += byteCount; value.peak = max(value.peak, value.live)
                return value.reservations
            }
            let lease = Lease(owner: self, bytes: byteCount)
            if index == cancelReservation { token.cancel() }
            return lease
        }
        private final class Lease: Sendable {
            let owner: Control
            let bytes: Int
            init(owner: Control, bytes: Int) { self.owner = owner; self.bytes = bytes }
            deinit { owner.state.withLock { $0.live -= bytes } }
        }
    }
}
