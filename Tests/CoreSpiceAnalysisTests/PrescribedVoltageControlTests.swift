import Testing
import Synchronization
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Prescribed voltage mandatory control", .timeLimit(.minutes(1)))
struct PrescribedVoltageControlTests {
    private typealias Reduction = PrescribedVoltageReduction
    private typealias E = CompensatedEnclosure
    private let limits = Reduction.Limits(maximumAxes: 100, maximumSources: 100,
        maximumWorkspaceBytes: 1_000_000, maximumResultBytes: 1_000_000)
    private let axes: [DCEquationKind] = [.electricalPotential, .electricalFlow]
    private let sources = [Reduction.Source(positiveRow: 0, negativeRow: nil, branchRow: 1)]

    private func budget(work: Int = 1_000_000) throws -> TransientExecutionBudget {
        try TransientExecutionBudget(limits: .init(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
            maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 100,
            maximumWorkUnits: work, maximumBreakpoints: 10), dimension: 1, nonZeroCount: 1, deviceCount: 0)
    }

    @Test func twoReductionsSpendTheSameAlreadyChargedInvocation() throws {
        let budget = try budget(work: 576), storage = Storage()
        let control = AnalysisLinearSolverControl(budget: budget, cancellation: CancellationToken(), storage: storage)
        try control.checkpoint(workUnits: 1)
        let first = try Reduction(limits: limits, control: control)
        let second = try Reduction(limits: limits, control: control)
        do {
            let plan = try first.prepare(axes: axes, sources: sources)
            #expect(budget.statistics.workUnits == 289)
            let retained = storage.live
            do {
                _ = try second.prepare(axes: axes, sources: sources)
                Issue.record("Second reduction reset shared invocation work")
            } catch TransientExecutionError.limitExceeded(let resource, let limit, let requested) {
                #expect(resource == "workUnits")
                #expect(limit == 576)
                #expect(requested == 577)
            }
            #expect(budget.statistics.workUnits == 321)
            #expect(storage.live == retained)
            withExtendedLifetime(plan) {}
        }
        #expect(storage.live == 0)
    }

    @Test func exactCheckpointAndReservationCausesPropagateWithoutPartialTables() throws {
        let storage = Storage(), lifetime = Lifetime()
        let control = Control(adapter: .init(budget: try budget(), cancellation: CancellationToken(), storage: storage), lifetime: lifetime)
        control.failCheckpoint = true
        #expect(throws: Cause.checkpoint) { try Reduction(limits: limits, control: control) }
        control.failCheckpoint = false
        let reduction = try Reduction(limits: limits, control: control)
        control.failCheckpoint = true
        #expect(throws: Cause.checkpoint) { try reduction.prepare(axes: axes, sources: sources) }
        #expect(storage.live == 0)
        control.failCheckpoint = false
        storage.failReservation = 2
        #expect(throws: Cause.reservation) { try reduction.prepare(axes: axes, sources: sources) }
        #expect(storage.live == 0)
        storage.failReservation = nil
        let plan = try reduction.prepare(axes: axes, sources: sources)
        #expect(plan.axisCount == 2)
    }

    @Test func actualAdapterCancellationBeforeAndDuringAdmissionIsPreserved() throws {
        for duringAdmission in [false, true] {
            let token = CancellationToken(), storage = Storage()
            let control = AnalysisLinearSolverControl(budget: try budget(), cancellation: token, storage: storage)
            let reduction = try Reduction(limits: limits, control: control)
            if duringAdmission { storage.cancelOnAdmission = token } else { token.cancel() }
            do {
                _ = try reduction.prepare(axes: axes, sources: sources)
                Issue.record("Expected exact cancellation failure")
            } catch AnalysisError.cancelled {}
            #expect(storage.live == 0)
        }
    }

    @Test func copiedPlanAndApplicationKeepOriginalControlAndLeasesAlive() throws {
        let storage = Storage(), lifetime = Lifetime()
        var planCopy: Reduction.Plan?
        var applicationCopy: Reduction.Application?
        do {
            let control = Control(adapter: .init(budget: try budget(), cancellation: CancellationToken(), storage: storage), lifetime: lifetime)
            let reduction = try Reduction(limits: limits, control: control)
            let plan = try reduction.prepare(axes: axes, sources: sources)
            let workspace = try reduction.makeWorkspace(plan: plan)
            let zero = try E(center: .zero)
            let two = try E(center: CompensatedValue(high: 2))
            let three = try E(center: CompensatedValue(high: 3))
            let application = try reduction.apply(workspace: workspace, reducedCoordinates: [], sourceValues: [two],
                staticResidual: [three, zero], stateChargeRate: [zero, zero],
                prescribedChargeRate: [zero, zero], explicitTimeChargeRate: [zero, zero])
            planCopy = plan
            applicationCopy = application
        }
        #expect(lifetime.controls == 1)
        #expect(storage.live > 0)
        #expect(try #require(applicationCopy).coordinate(at: 1).center.high == -3)
        applicationCopy = nil
        #expect(lifetime.controls == 1)
        #expect(storage.live > 0)
        #expect(try #require(planCopy).axisCount == 2)
        planCopy = nil
        #expect(lifetime.controls == 0)
        #expect(storage.live == 0)
    }

    private enum Cause: Error, Equatable { case checkpoint, reservation }
    private final class Lifetime: Sendable {
        let state = Mutex(0)
        var controls: Int { state.withLock { $0 } }
    }
    private final class Control: LinearSolverExecutionControlling {
        let adapter: AnalysisLinearSolverControl
        let lifetime: Lifetime
        private let failure = Mutex(false)
        var failCheckpoint: Bool {
            get { failure.withLock { $0 } }
            set { failure.withLock { $0 = newValue } }
        }
        init(adapter: AnalysisLinearSolverControl, lifetime: Lifetime) {
            self.adapter = adapter; self.lifetime = lifetime
            lifetime.state.withLock { $0 += 1 }
        }
        deinit { lifetime.state.withLock { $0 -= 1 } }
        func checkpoint(workUnits: Int) throws {
            if failure.withLock({ $0 }) { throw Cause.checkpoint }
            try adapter.checkpoint(workUnits: workUnits)
        }
        func reserveStorage(byteCount: Int) throws -> any Sendable { try adapter.reserveStorage(byteCount: byteCount) }
    }
    private final class Storage: AnalysisResultStorageAccounting, Sendable {
        private struct State {
            var live = 0
            var reservations = 0
            var failReservation: Int?
            var cancellation: CancellationToken?
        }
        private let state = Mutex(State())
        var live: Int { state.withLock { $0.live } }
        var failReservation: Int? {
            get { state.withLock { $0.failReservation } }
            set { state.withLock { $0.failReservation = newValue } }
        }
        var cancelOnAdmission: CancellationToken? {
            get { state.withLock { $0.cancellation } }
            set { state.withLock { $0.cancellation = newValue } }
        }
        func reserveResultScalars(_ capacity: Int) throws { Issue.record("Unexpected waveform scalar admission") }
        func reserveTemporaryBytes(_ bytes: UInt64) throws -> any Sendable {
            let count = try #require(Int(exactly: bytes))
            let cancellation = try state.withLock { value in
                value.reservations += 1
                if value.reservations == value.failReservation { throw Cause.reservation }
                value.live += count
                return value.cancellation
            }
            let lease = Lease(owner: self, count: count)
            cancellation?.cancel()
            return lease
        }
        private final class Lease: Sendable {
            let owner: Storage
            let count: Int
            init(owner: Storage, count: Int) { self.owner = owner; self.count = count }
            deinit { owner.state.withLock { $0.live -= count } }
        }
    }
}
