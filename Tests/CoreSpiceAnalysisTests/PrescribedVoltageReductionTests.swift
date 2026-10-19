import Testing
import Synchronization
import CoreSpiceDevices
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Prescribed voltage forest reduction", .timeLimit(.minutes(1)))
struct PrescribedVoltageReductionTests {
    typealias Reduction = PrescribedVoltageReduction
    typealias E = CompensatedEnclosure
    private func number(_ value: Double) throws -> E { try E(center: CompensatedValue(high: value)) }
    private func values(_ numbers: [Double]) throws -> [E] { try numbers.map(number) }
    private func setup(work: Int = 1_000_000, workspace: Int = 1_000_000, result: Int = 1_000_000,
        storage: Storage = Storage(), token: CancellationToken = CancellationToken()) throws -> (Reduction, TransientExecutionBudget, Storage) {
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 10, maximumSolveAttempts: 10,
            maximumNewtonIterations: 10, maximumSavedScalars: 100, maximumMatrixDimension: 100,
            maximumWorkUnits: work, maximumBreakpoints: 10)
        let budget = try TransientExecutionBudget(limits: limits, dimension: 1, nonZeroCount: 1, deviceCount: 0)
        let reduction = try Reduction(limits: .init(maximumAxes: 100, maximumSources: 100,
            maximumWorkspaceBytes: workspace, maximumResultBytes: result), budget: budget, storage: storage, cancellation: token)
        return (reduction, budget, storage)
    }
    private func apply(_ reduction: Reduction, _ workspace: Reduction.Workspace,
        reduced: [Double], sources: [Double], residual: [Double], charge: [Double]? = nil) throws -> Reduction.Application {
        let zeros = [Double](repeating: 0, count: residual.count)
        return try reduction.apply(workspace: workspace, reducedCoordinates: values(reduced), sourceValues: values(sources),
            staticResidual: values(residual), stateChargeRate: values(zeros),
            prescribedChargeRate: values(charge ?? zeros), explicitTimeChargeRate: values(zeros))
    }
    private func expectCenter(_ actual: E, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.center.high == expected, sourceLocation: sourceLocation)
        #expect(actual.center.low == 0, sourceLocation: sourceLocation)
    }

    @Test func exactIntegerBasisChecksAllSparseIdentitiesAndSourceOrders() throws {
        let (reduction, _, _) = try setup()
        let axes: [DCEquationKind] = [.electricalPotential, .electricalPotential, .electricalPotential,
            .electricalPotential, .electricalFlow, .electricalFlow, .electricalFlow]
        let sources: [Reduction.Source] = [.init(positiveRow: 2, negativeRow: 1, branchRow: 5),
            .init(positiveRow: 1, negativeRow: nil, branchRow: 4), .init(positiveRow: 3, negativeRow: 0, branchRow: 6)]
        let plan = try reduction.prepare(axes: axes, sources: sources)
        let scratch = try reduction.makeWorkspace(plan: plan)
        #expect(plan.reducedCount == 1)
        #expect(try plan.rootRow(at: 3) == 0)
        #expect(try plan.rootRow(at: 2) == nil)
        #expect(try plan.parentRow(at: 2) == 1)
        #expect(try plan.sourceEdge(at: 2) == 0)
        #expect(try plan.sourceSign(at: 2) == 1)
        let zeros = [Double](repeating: 0, count: axes.count)
        // G^T E=I and G^T A=0, with source constraints independently replayed.
        for column in 0..<4 {
            var u = [Double](repeating: 0, count: sources.count)
            if column < 3 { u[column] = 1 }
            let output = try apply(reduction, scratch, reduced: [column == 3 ? 1 : 0], sources: u, residual: zeros)
            for (index, source) in sources.enumerated() {
                let positive = try source.positiveRow.map { try output.coordinate(at: $0).center.high } ?? 0
                let negative = try source.negativeRow.map { try output.coordinate(at: $0).center.high } ?? 0
                #expect(positive - negative == u[index])
                expectCenter(try output.originalResidual(at: source.branchRow), 0)
            }
        }
        // K G=I and P G=0; reconstructed -K G is minus the selected basis vector.
        for (column, source) in sources.enumerated() {
            var g = zeros
            if let positive = source.positiveRow { g[positive] = 1 }
            if let negative = source.negativeRow { g[negative] = -1 }
            let output = try apply(reduction, scratch, reduced: [0], sources: [0, 0, 0], residual: g)
            for (index, edge) in sources.enumerated() {
                expectCenter(try output.coordinate(at: edge.branchRow), column == index ? -1 : 0)
            }
            expectCenter(try output.reducedResidual(at: 0), 0)
            for row in axes.indices { expectCenter(try output.originalResidual(at: row), 0) }
        }
    }

    @Test func capacitorParallelToNonconstantGivenInputRetainsInputChargeRateAndSigns() throws {
        for reversed in [false, true] {
            let (reduction, budget, _) = try setup()
            let source = Reduction.Source(positiveRow: reversed ? nil : 0, negativeRow: reversed ? 0 : nil, branchRow: 1)
            let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow], sources: [source])
            let scratch = try reduction.makeWorkspace(plan: plan)
            #expect(plan.reducedCount == 0)
            // Caller-authorized jet u=2,u'=4 and C=3: Qu*u' is +/-12 on the node row.
            let output = try apply(reduction, scratch, reduced: [], sources: [2], residual: [0, 0],
                charge: [reversed ? -12 : 12, 0])
            expectCenter(try output.coordinate(at: 0), reversed ? -2 : 2)
            expectCenter(try output.coordinate(at: 1), -12)
            expectCenter(try output.originalResidual(at: 0), 0)
            expectCenter(try output.originalResidual(at: 1), 0)
            #expect(budget.statistics.solveAttempts == 0)
            #expect(budget.statistics.newtonIterations == 0)
        }
    }

    @Test func floatingUnbalancedKCLRemainsAnExplicitResidualObligation() throws {
        let (reduction, _, _) = try setup()
        let plan = try reduction.prepare(axes: [.electricalPotential, .electricalPotential, .electricalFlow],
            sources: [.init(positiveRow: 1, negativeRow: 0, branchRow: 2)])
        let scratch = try reduction.makeWorkspace(plan: plan)
        let output = try apply(reduction, scratch, reduced: [10], sources: [3], residual: [1, 1, 0])
        expectCenter(try output.coordinate(at: 0), 10)
        expectCenter(try output.coordinate(at: 1), 13)
        expectCenter(try output.coordinate(at: 2), -1)
        expectCenter(try output.reducedResidual(at: 0), 2)
        expectCenter(try output.originalResidual(at: 0), 2)
        expectCenter(try output.originalResidual(at: 1), 0)
    }

    @Test func everyUntouchedBodyInternalFlowAndThermalAxisIsRetained() throws {
        let (reduction, _, _) = try setup()
        let axes: [DCEquationKind] = [.electricalPotential, .electricalPotential, .electricalPotential,
            .electricalFlow, .thermalPotential, .electricalFlow]
        let plan = try reduction.prepare(axes: axes, sources: [.init(positiveRow: 1, negativeRow: 0, branchRow: 3)])
        #expect(plan.reducedCount == 4)
        let scratch = try reduction.makeWorkspace(plan: plan)
        let output = try apply(reduction, scratch, reduced: [10, 20, 30, 40], sources: [2], residual: [0, 0, 7, 0, 11, 13])
        for row in axes.indices { #expect(try plan.nature(at: row) == axes[row]) }
        expectCenter(try output.coordinate(at: 2), 20)
        expectCenter(try output.coordinate(at: 4), 30)
        expectCenter(try output.coordinate(at: 5), 40)
        for (row, expected) in [(2, 7.0), (4, 11.0), (5, 13.0)] {
            expectCenter(try output.originalResidual(at: row), expected)
            let mapped = try plan.reducedCoordinate(at: row)
            let coordinate = try #require(mapped)
            expectCenter(try output.reducedResidual(at: coordinate), expected)
        }
    }

    @Test func residualContainingZeroRemainsAnUnclosedEnclosure() throws {
        let (reduction, _, _) = try setup()
        let plan = try reduction.prepare(axes: [.electricalPotential], sources: [])
        let scratch = try reduction.makeWorkspace(plan: plan)
        let zero = try number(0), uncertain = try E(center: .zero, radius: 1)
        let output = try reduction.apply(workspace: scratch, reducedCoordinates: [zero], sourceValues: [],
            staticResidual: [uncertain], stateChargeRate: [zero], prescribedChargeRate: [zero], explicitTimeChargeRate: [zero])
        let original = try output.originalResidual(at: 0)
        let reduced = try output.reducedResidual(at: 0)
        #expect(original.center == .zero)
        #expect(original.radius >= 1)
        #expect(reduced == original)
    }

    @Test func noSourcesIsTheIdentityWithoutDroppingAnyAxis() throws {
        let (reduction, _, _) = try setup()
        let plan = try reduction.prepare(axes: [.thermalPotential, .electricalFlow, .electricalPotential], sources: [])
        let scratch = try reduction.makeWorkspace(plan: plan)
        let output = try apply(reduction, scratch, reduced: [1, 2, 3], sources: [], residual: [4, 5, 6])
        #expect(plan.reducedCount == 3)
        for row in 0..<3 {
            expectCenter(try output.coordinate(at: row), Double(row + 1))
            expectCenter(try output.originalResidual(at: row), Double(row + 4))
            expectCenter(try output.reducedResidual(at: row), Double(row + 4))
        }
    }

    @Test func selfLoopsParallelSourcesAndCyclesRefuseWithoutChoosingCurrents() throws {
        let (reduction, _, storage) = try setup()
        #expect(throws: Reduction.Failure.selfLoop(source: 0)) {
            try reduction.prepare(axes: [.electricalFlow], sources: [.init(positiveRow: nil, negativeRow: nil, branchRow: 0)])
        }
        #expect(throws: Reduction.Failure.dependentSources) {
            try reduction.prepare(axes: [.electricalPotential, .electricalFlow, .electricalFlow], sources: [
                .init(positiveRow: 0, negativeRow: nil, branchRow: 1), .init(positiveRow: 0, negativeRow: nil, branchRow: 2)])
        }
        #expect(throws: Reduction.Failure.dependentSources) {
            try reduction.prepare(axes: [.electricalPotential, .electricalPotential, .electricalFlow, .electricalFlow, .electricalFlow], sources: [
                .init(positiveRow: 0, negativeRow: nil, branchRow: 2), .init(positiveRow: 1, negativeRow: 0, branchRow: 3),
                .init(positiveRow: nil, negativeRow: 1, branchRow: 4)])
        }
        #expect(storage.live == 0)
    }

    @Test func malformedNatureIndicesDuplicateBranchesAndSourceConstraintTermsRefuse() throws {
        let (reduction, _, storage) = try setup()
        for source in [Reduction.Source(positiveRow: 2, negativeRow: nil, branchRow: 1),
                       .init(positiveRow: -1, negativeRow: nil, branchRow: 1),
                       .init(positiveRow: 0, negativeRow: nil, branchRow: 0)] {
            #expect(throws: Reduction.Failure.invalidInput) {
                try reduction.prepare(axes: [.thermalPotential, .electricalFlow], sources: [source])
            }
        }
        #expect(throws: Reduction.Failure.invalidInput) {
            try reduction.prepare(axes: [.electricalPotential, .electricalFlow], sources: [
                .init(positiveRow: 0, negativeRow: nil, branchRow: 1), .init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
        }
        do {
            let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow], sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
            let scratch = try reduction.makeWorkspace(plan: plan)
            #expect(throws: Reduction.Failure.invalidInput) {
                try apply(reduction, scratch, reduced: [], sources: [1], residual: [0, 1])
            }
            #expect(throws: Reduction.Failure.invalidInput) { try plan.nature(at: -1) }
        }
        #expect(storage.live == 0)
    }

    @Test func allArrayInitializationIsPreadmittedAndWorkIsInvocationCumulative() throws {
        let (small, budget, storage) = try setup(work: 31)
        do {
            _ = try small.prepare(axes: [.electricalPotential, .electricalFlow], sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
            Issue.record("Expected complete 32-element initialization admission refusal")
        } catch TransientExecutionError.limitExceeded(let resource, let limit, let requested) {
            #expect(resource == "workUnits"); #expect(limit == 31); #expect(requested == 32)
        }
        #expect(budget.statistics.workUnits == 0)
        #expect(storage.live == 0)
        let (bounded, cumulative, retained) = try setup(work: 288)
        do {
            let plan = try bounded.prepare(axes: [.electricalPotential, .electricalFlow], sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
            #expect(cumulative.statistics.workUnits == 288)
            do { _ = try bounded.makeWorkspace(plan: plan); Issue.record("A new workspace reset invocation work") }
            catch TransientExecutionError.limitExceeded(let resource, _, _) { #expect(resource == "workUnits") }
        }
        #expect(retained.live == 0)
    }

    @Test func capacityOverflowAndStorageCeilingsRefuseAndRefund() throws {
        for count in [Int.max, Int.max / 2] {
            #expect(throws: TransientExecutionError.self) { try Reduction.capacity(axisCount: count, sourceCount: 1) }
            #expect(throws: TransientExecutionError.self) { try Reduction.capacity(axisCount: 1, sourceCount: count) }
        }
        let source = Reduction.Source(positiveRow: 0, negativeRow: nil, branchRow: 1)
        let (noScratch, _, storageA) = try setup(workspace: 1)
        #expect(throws: Reduction.Failure.workspaceLimit) { try noScratch.prepare(axes: [.electricalPotential, .electricalFlow], sources: [source]) }
        #expect(storageA.live == 0)
        let (noResult, _, storageB) = try setup(result: 1)
        #expect(throws: Reduction.Failure.resultLimit) { try noResult.prepare(axes: [.electricalPotential, .electricalFlow], sources: [source]) }
        #expect(storageB.live == 0)
        let tiny = Storage(capacity: 1)
        let (noCapacity, _, _) = try setup(storage: tiny)
        #expect(throws: Storage.Refusal.capacity) { try noCapacity.prepare(axes: [.electricalPotential, .electricalFlow], sources: [source]) }
        #expect(tiny.live == 0)
    }

    @Test func outputInitializationCannotSpendUnusedLoopCreditsAndRefundsItsLease() throws {
        let (reduction, budget, storage) = try setup(work: 550)
        let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow],
            sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
        let scratch = try reduction.makeWorkspace(plan: plan)
        let retained = storage.live
        do {
            _ = try apply(reduction, scratch, reduced: [], sources: [2], residual: [0, 0])
            Issue.record("Output initialization incorrectly reused arithmetic loop credits")
        } catch TransientExecutionError.limitExceeded(let resource, let limit, let requested) {
            #expect(resource == "workUnits"); #expect(limit == 550); #expect(requested == 554)
        }
        #expect(budget.statistics.workUnits == 550)
        #expect(storage.live == retained)
        withExtendedLifetime(scratch) {}
    }

    @Test func numericalFailureDoesNotPublishOrPoisonReusableScratch() throws {
        let (reduction, _, storage) = try setup()
        let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow],
            sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
        let scratch = try reduction.makeWorkspace(plan: plan)
        let retained = storage.live
        #expect(throws: NumericalStateError.self) {
            try apply(reduction, scratch, reduced: [], sources: [0], residual: [.greatestFiniteMagnitude, 0],
                charge: [.greatestFiniteMagnitude, 0])
        }
        #expect(storage.live == retained)
        let retry = try apply(reduction, scratch, reduced: [], sources: [2], residual: [3, 0])
        expectCenter(try retry.coordinate(at: 1), -3)
        expectCenter(try retry.originalResidual(at: 0), 0)
    }

    @Test func cancellationBeforeAndAfterStorageAdmissionNeverPublishesTables() throws {
        for afterAdmission in [false, true] {
            let token = CancellationToken(), storage = Storage()
            let (reduction, _, _) = try setup(storage: storage, token: token)
            if afterAdmission { storage.cancelOnAdmission = token } else { token.cancel() }
            do {
                _ = try reduction.prepare(axes: [.electricalPotential, .electricalFlow], sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
                Issue.record("Expected exact cancellation failure")
            } catch AnalysisError.cancelled {}
            #expect(storage.live == 0)
        }
    }

    @Test func copiedOutputsRetainAllArraysAndReusableWorkspaceCannotResetOwners() throws {
        let (reduction, _, storage) = try setup()
        var copy: Reduction.Application?
        do {
            let plan = try reduction.prepare(axes: [.electricalPotential, .electricalFlow], sources: [.init(positiveRow: 0, negativeRow: nil, branchRow: 1)])
            let scratch = try reduction.makeWorkspace(plan: plan)
            let first = try apply(reduction, scratch, reduced: [], sources: [2], residual: [5, 0])
            copy = first
            let second = try apply(reduction, scratch, reduced: [], sources: [3], residual: [7, 0])
            expectCenter(try first.coordinate(at: 1), -5)
            expectCenter(try second.coordinate(at: 1), -7)
            let (other, _, _) = try setup()
            #expect(throws: Reduction.Failure.wrongOwner) { try other.makeWorkspace(plan: plan) }
            #expect(throws: Reduction.Failure.wrongOwner) {
                try apply(other, scratch, reduced: [], sources: [0], residual: [0, 0])
            }
        }
        withExtendedLifetime(copy) { #expect(storage.live > 0) }
        expectCenter(try #require(copy).coordinate(at: 1), -5)
        copy = nil
        #expect(storage.live == 0)
    }

    @Test func taskCancellationCannotReturnAnApplication() async throws {
        let (reduction, _, storage) = try setup()
        let refused = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try reduction.prepare(axes: [.electricalPotential], sources: [])
                return false
            } catch AnalysisError.cancelled { return true }
            catch { return false }
        }.value
        #expect(refused)
        #expect(storage.live == 0)
    }

    private final class Storage: AnalysisResultStorageAccounting, Sendable {
        enum Refusal: Error, Equatable { case capacity }
        private struct State { var live = 0; var cancellation: CancellationToken? }
        private let state = Mutex(State())
        let capacity: Int
        init(capacity: Int = 10_000_000) { self.capacity = capacity }
        var live: Int { state.withLock { $0.live } }
        var cancelOnAdmission: CancellationToken? {
            get { state.withLock { $0.cancellation } }
            set { state.withLock { $0.cancellation = newValue } }
        }
        func reserveResultScalars(_ capacity: Int) throws { Issue.record("Reduction payload was miscounted as saved waveform scalars") }
        func reserveTemporaryBytes(_ bytes: UInt64) throws -> any Sendable {
            let count = try #require(Int(exactly: bytes))
            let cancellation = try state.withLock { value in
                guard count <= capacity - value.live else { throw Refusal.capacity }
                value.live += count; return value.cancellation
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
