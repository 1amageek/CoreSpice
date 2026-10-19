import Testing
import Synchronization
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIR

@Suite("Analysis Sparse Execution Control", .timeLimit(.minutes(1)))
struct AnalysisLinearSolverControlTests {
    private enum Refusal: Error, Equatable { case capacity; case numerical }

    private final class Storage: AnalysisResultStorageAccounting {
        struct State: Sendable { var liveBytes = 0; var peakBytes = 0; var reservations = 0 }
        let state = Mutex(State())
        let capacity: Int
        let cancellation: CancellationToken?

        init(capacity: Int, cancellation: CancellationToken? = nil) {
            self.capacity = capacity
            self.cancellation = cancellation
        }

        func reserveResultScalars(_ capacity: Int) throws {}

        func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
            let count = try #require(Int(exactly: byteCount))
            try state.withLock { state in
                guard count <= capacity - state.liveBytes else { throw Refusal.capacity }
                state.liveBytes += count
                state.peakBytes = max(state.peakBytes, state.liveBytes)
                state.reservations += 1
            }
            cancellation?.cancel()
            return Lease(storage: self, bytes: count)
        }

        private final class Lease: Sendable {
            let storage: Storage
            let bytes: Int
            init(storage: Storage, bytes: Int) { self.storage = storage; self.bytes = bytes }
            deinit { storage.state.withLock { $0.liveBytes -= bytes } }
        }
    }

    private func budget(work: Int = 100_000) throws -> TransientExecutionBudget {
        try TransientExecutionBudget(limits: .init(maximumAcceptedSteps: 10,
            maximumSolveAttempts: 10, maximumNewtonIterations: 10, maximumSavedScalars: 100,
            maximumMatrixDimension: 10, maximumWorkUnits: work, maximumBreakpoints: 10),
            dimension: 1, nonZeroCount: 1, deviceCount: 0)
    }

    @Test("Sparse iteration admission does not precharge dense work")
    func sparseAdmission() throws {
        let limits = TransientExecutionLimits(maximumAcceptedSteps: 1, maximumSolveAttempts: 10,
            maximumNewtonIterations: 1, maximumSavedScalars: 1, maximumMatrixDimension: 100_000,
            maximumWorkUnits: 1_000_000, maximumBreakpoints: 1)
        let budget = try TransientExecutionBudget(limits: limits, dimension: 100_000,
            nonZeroCount: 100_000, deviceCount: 0)
        try budget.beginIteration()
        #expect(budget.statistics.workUnits == 1_000_000)
        #expect(throws: TransientExecutionError.self) { try budget.beginDenseLinearSolve() }
    }

    @Test("Controller shares cumulative work and a new run starts independently")
    func cumulativeWork() throws {
        let budget = try budget(work: 20)
        let control = AnalysisLinearSolverControl(budget: budget, cancellation: CancellationToken(), storage: nil)
        try control.checkpoint(workUnits: 12)
        #expect(throws: TransientExecutionError.limitExceeded(resource: "workUnits", limit: 20, requested: 21)) {
            try control.checkpoint(workUnits: 9)
        }
        #expect(budget.statistics.workUnits == 12)
        let next = try self.budget(work: 20)
        try AnalysisLinearSolverControl(budget: next, cancellation: CancellationToken(), storage: nil)
            .checkpoint(workUnits: 20)
        #expect(next.statistics.workUnits == 20)
    }

    @Test("Storage admission retains its owner and final lease release restores capacity")
    func storageLease() throws {
        let storage = Storage(capacity: 24)
        let control = AnalysisLinearSolverControl(budget: nil, cancellation: CancellationToken(), storage: storage)
        var lease: (any Sendable)? = try control.reserveStorage(byteCount: 24)
        var retained = lease
        lease = nil
        #expect(storage.state.withLock { $0.liveBytes } == 24)
        #expect(throws: Refusal.capacity) { _ = try control.reserveStorage(byteCount: 1) }
        withExtendedLifetime(retained) {}
        retained = nil
        #expect(storage.state.withLock { $0.liveBytes } == 0)
        #expect(storage.state.withLock { $0.peakBytes } == 24)
    }

    @Test("Cancellation after resource admission releases the newly admitted lease")
    func cancellationAfterAdmission() throws {
        let token = CancellationToken()
        let storage = Storage(capacity: 24, cancellation: token)
        let control = AnalysisLinearSolverControl(budget: nil, cancellation: token, storage: storage)
        #expect(throws: AnalysisError.self) { _ = try control.reserveStorage(byteCount: 24) }
        #expect(storage.state.withLock { $0.liveBytes } == 0)
        #expect(storage.state.withLock { $0.reservations } == 1)
        #expect(throws: AnalysisError.self) { try control.checkpoint(workUnits: 0) }
    }

    @Test("Task cancellation is observed without cancelling the explicit token")
    func taskCancellation() async throws {
        let token = CancellationToken()
        let control = AnalysisLinearSolverControl(budget: nil, cancellation: token, storage: nil)
        let cancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try control.checkpoint(workUnits: 0); return false }
            catch AnalysisError.cancelled { return true }
            catch { return false }
        }.value
        #expect(cancelled)
        #expect(!token.isCancelled)
    }

    private struct RefusingSolver: LinearSolver {
        mutating func factorize(matrix: SparseMatrix) throws { throw Refusal.numerical }
        func solve(rhs: [Double]) throws -> [Double] { rhs }
    }

    private struct FailingSolver: LinearSolver {
        enum Phase: Sendable, Equatable { case factor; case solve; case refinement }
        let phase: Phase
        var calls = 0
        mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {}
        mutating func factorize(matrix: SparseMatrix) throws {
            if phase == .factor { throw Refusal.numerical }
        }
        func solve(rhs: [Double]) throws -> [Double] { throw Refusal.numerical }
        mutating func solve(rhs: [Double], into result: inout [Double]) throws {
            calls += 1
            if phase == .solve || (phase == .refinement && calls > 1) { throw Refusal.numerical }
            result[0] = 0.5
        }
    }

    private func runNewton(solver: inout any LinearSolver, budget: TransientExecutionBudget?,
        storage: (any AnalysisResultStorageAccounting)? = nil,
        cancellation: CancellationToken = CancellationToken()) async throws {
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: 1, entries: [(0, 0)]))
        var rhs = [1.0]
        var newton = NewtonRaphsonSolver(config: .init(abstol: 1e-15, reltol: 1e-12,
            vntol: 1e-12, maxIterations: 2, gmin: 0))
        newton.executionBudget = budget
        newton.resultStorage = storage
        _ = try await newton.solve(initialGuess: [1], matrix: &matrix, rhs: &rhs,
            devices: [], variableMap: [.nodeVoltage(Node(id: 1)): 0], solver: &solver,
            stampFunction: { stamper, _ in
                stamper.stampMatrix(0, 0, 1); stamper.stampRHS(0, 1)
            }, observer: nil, analysisID: AnalysisID(), cancellation: cancellation)
    }

    @Test("Bounded solvers must explicitly support execution control")
    func unsupportedControl() async throws {
        var solver: any LinearSolver = RefusingSolver()
        do {
            try await runNewton(solver: &solver, budget: budget())
            Issue.record("Expected explicit refusal of bounded execution")
        } catch SparseSolverError.executionControlUnsupported {}
        do {
            try await runNewton(solver: &solver, budget: nil)
            Issue.record("Expected the original unbounded solver failure")
        } catch Refusal.numerical {}
    }

    @Test("Factor, solve and refinement failures retain their typed cause", arguments: [
        FailingSolver.Phase.factor, .solve, .refinement
    ])
    private func typedFailure(_ phase: FailingSolver.Phase) async throws {
        var solver: any LinearSolver = FailingSolver(phase: phase)
        do {
            try await runNewton(solver: &solver, budget: budget())
            Issue.record("Expected the original numerical failure")
        } catch Refusal.numerical {}
    }

    @Test("Native sparse kernel work refusal propagates through Newton")
    func actualKernelWorkRefusal() async throws {
        var solver: any LinearSolver = SparseLUSolver()
        do {
            try await runNewton(solver: &solver, budget: budget(work: 10))
            Issue.record("Actual sparse kernel must charge work beyond stamping")
        } catch TransientExecutionError.limitExceeded(let resource, _, _) {
            #expect(resource == "workUnits")
        }
    }

    @Test("Native sparse storage refusal propagates through Newton")
    func actualKernelStorageRefusal() async throws {
        var solver: any LinearSolver = SparseLUSolver()
        do {
            try await runNewton(solver: &solver, budget: nil, storage: Storage(capacity: 0))
            Issue.record("Actual sparse kernel must admit storage")
        } catch Refusal.capacity {}
    }

    @Test("Actual sparse preparation observes the token and releases admitted capacity")
    func actualKernelCancellation() async throws {
        let token = CancellationToken()
        let storage = Storage(capacity: 1_000_000, cancellation: token)
        var solver: any LinearSolver = SparseLUSolver()
        do {
            try await runNewton(solver: &solver, budget: nil, storage: storage, cancellation: token)
            Issue.record("Expected cancellation inside sparse preparation")
        } catch AnalysisError.cancelled {}
        #expect(storage.state.withLock { $0.reservations } == 1)
        #expect(storage.state.withLock { $0.liveBytes } == 0)
    }

    @Test("Actual sparse factors retain capacity until the last solver copy is released")
    func actualKernelLeaseRelease() throws {
        let storage = Storage(capacity: 1_000_000)
        let control = AnalysisLinearSolverControl(budget: nil, cancellation: CancellationToken(), storage: storage)
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: 1, entries: [(0, 0)]))
        matrix.addValue(row: 0, col: 0, value: 2)
        var retained: SparseLUSolver?
        do {
            var solver = SparseLUSolver()
            try solver.configureExecution(control)
            try solver.factorize(matrix: matrix)
            retained = solver
        }
        #expect(storage.state.withLock { $0.liveBytes } > 0)
        #expect(try retained?.solve(rhs: [4]) == [2])
        withExtendedLifetime(retained) {}
        retained = nil
        #expect(storage.state.withLock { $0.liveBytes } == 0)
    }
}
