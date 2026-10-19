import Foundation
import Testing
import Synchronization
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
import CoreSpiceIR
import CoreSpiceEvent

@Suite("Newton Linear Refinement", .timeLimit(.minutes(1)))
struct NewtonLinearRefinementTests {
    private struct Fixture: Decodable {
        struct System: Decodable { let rowPointers: [Int]; let columnIndices: [Int]; let valuesHex: [String]; let rhsHex: [String] }
        struct Config: Decodable { let abstolHex: String; let reltolHex: String; let vntolHex: String }
        let dimension: Int
        let solve: System
        let branchCurrentIndices: [Int]
        let config: Config
        let capturedRawSolutionHex: [String]
        let referenceSolutionHex: [String]
    }

    private func number(_ word: String) throws -> Double {
        Double(bitPattern: try #require(UInt64(word, radix: 16)))
    }

    @Test("Retained native systems meet the unchanged physical residual gate", arguments: [455, 847])
    func retainedSystem(_ dimension: Int) async throws {
        let url = try #require(Bundle.module.url(forResource: "retained-d\(dimension)", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let structure = try SparseStructure(dimension: fixture.dimension, rowPointers: fixture.solve.rowPointers, columnIndices: fixture.solve.columnIndices)
        let values = try fixture.solve.valuesHex.map(number)
        let frozenRHS = try fixture.solve.rhsHex.map(number)
        let raw = try fixture.capturedRawSolutionHex.map(number)
        var matrix = SparseMatrix(structure: structure)
        var rhs = frozenRHS
        let branches = Set(fixture.branchCurrentIndices)
        var map: [MNAVariable: Int] = [:]
        for i in 0..<dimension { map[branches.contains(i) ? .branchCurrent(Branch(id: i)) : .nodeVoltage(Node(id: i + 1))] = i }
        let config = try ConvergenceConfig(abstol: number(fixture.config.abstolHex), reltol: number(fixture.config.reltolHex), vntol: number(fixture.config.vntolHex), maxIterations: 3, gmin: 0)
        let counts = Counts()
        var solver: any LinearSolver = CountingSolver(inner: SparseLUSolver(), counts: counts)
        let budget = try TransientExecutionBudget(limits: limits(), dimension: dimension,
            nonZeroCount: values.count, deviceCount: 0)
        var newton = NewtonRaphsonSolver(config: config)
        newton.executionBudget = budget
        let result = try await newton.solve(initialGuess: raw, matrix: &matrix, rhs: &rhs, devices: [], variableMap: map, solver: &solver, stampFunction: { stamper, _ in
            for i in values.indices { stamper.stampValue?(i, values[i]) }
            for i in frozenRHS.indices { stamper.stampRHS(i, frozenRHS[i]) }
        }, observer: nil, analysisID: AnalysisID(), cancellation: CancellationToken())
        #expect(result.iterations <= 3)
        let operations = counts.snapshot
        // Accurate factors may already satisfy the unchanged original-system gate.
        #expect(operations.solves >= operations.factors)
        #expect(budget.statistics.solveAttempts == 1 + operations.solves - operations.factors)
        #expect(budget.statistics.newtonIterations == result.iterations)
        var residual = [Double](repeating: 0, count: dimension)
        try matrix.checkedResidual(vector: result.solution, rhs: frozenRHS, into: &residual)
        let reference = try fixture.referenceSolutionHex.map(number)
        var oracleResidual = [Double](repeating: 0, count: dimension)
        try matrix.checkedResidual(vector: reference, rhs: frozenRHS, into: &oracleResidual)
        for i in 0..<dimension {
            let tolerance = (branches.contains(i) ? config.vntol : config.abstol) + config.reltol * abs(frozenRHS[i])
            #expect(abs(residual[i]) <= tolerance)
            #expect(abs(oracleResidual[i]) <= tolerance)
        }
    }

    @Test("Product rounding does not falsely reject an exact linear solution")
    func exactProductResidual() async throws {
        let g = 1e16
        let d = Double.ulpOfOne
        let x = [1 + d, 1, -g * d]
        let structure = try SparseStructure.fromTriplets(dimension: 3, entries: [(0, 0), (0, 1), (0, 2), (1, 1), (2, 2)])
        var matrix = SparseMatrix(structure: structure)
        var rhs = [0.0, 1, x[2]]
        var solver: any LinearSolver = FixedSolver(value: x)
        _ = try await NewtonRaphsonSolver(config: ConvergenceConfig(abstol: 1e-15, reltol: 1e-12, vntol: 1e-12, maxIterations: 2, gmin: 0)).solve(initialGuess: x, matrix: &matrix, rhs: &rhs, devices: [], variableMap: [.nodeVoltage(Node(id: 1)): 0, .nodeVoltage(Node(id: 2)): 1, .nodeVoltage(Node(id: 3)): 2], solver: &solver, stampFunction: { stamper, _ in
            stamper.stampMatrix(0, 0, g); stamper.stampMatrix(0, 1, -g); stamper.stampMatrix(0, 2, 1)
            stamper.stampMatrix(1, 1, 1); stamper.stampMatrix(2, 2, 1)
            stamper.stampRHS(1, 1); stamper.stampRHS(2, x[2])
        }, observer: nil, analysisID: AnalysisID(), cancellation: CancellationToken())
    }

    private func limits(solves: Int = 10000, work: Int = Int.max) -> TransientExecutionLimits {
        .init(maximumAcceptedSteps: 100, maximumSolveAttempts: solves,
            maximumNewtonIterations: 100, maximumSavedScalars: 10000,
            maximumMatrixDimension: 1000, maximumWorkUnits: work, maximumBreakpoints: 100)
    }

    private final class Counts: Sendable {
        struct State: Sendable { var solves = 0; var factors = 0 }
        let value = Mutex(State())
        var snapshot: State { value.withLock { $0 } }
    }

    private struct CountingSolver: LinearSolver {
        var inner: SparseLUSolver
        let counts: Counts
        mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {
            try inner.configureExecution(control)
        }
        mutating func factorize(matrix: SparseMatrix) throws {
            counts.value.withLock { $0.factors += 1 }
            try inner.factorize(matrix: matrix)
        }
        func solve(rhs: [Double]) throws -> [Double] { try inner.solve(rhs: rhs) }
        mutating func solve(rhs: [Double], into result: inout [Double]) throws {
            counts.value.withLock { $0.solves += 1 }
            try inner.solve(rhs: rhs, into: &result)
        }
    }

    private struct InjectedSolver: LinearSolver {
        let counts: Counts
        let correction: Double?
        let cancellation: CancellationToken?
        var control: (any LinearSolverExecutionControlling)?
        mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {
            self.control = control
        }
        mutating func factorize(matrix: SparseMatrix) throws {
            try control?.checkpoint(workUnits: 1)
            counts.value.withLock { $0.factors += 1 }
        }
        func solve(rhs: [Double]) throws -> [Double] { rhs }
        mutating func solve(rhs: [Double], into result: inout [Double]) throws {
            try control?.checkpoint(workUnits: 1)
            let attempt = counts.value.withLock { state in state.solves += 1; return state.solves }
            result[0] = attempt == 1 ? 0.5 : (correction ?? rhs[0])
            if attempt == 2 { cancellation?.cancel() }
        }
    }

    private func smallSolve(budget: TransientExecutionBudget, counts: Counts,
        correction: Double? = nil, cancellation: CancellationToken = CancellationToken(),
        cancelDuringCorrection: Bool = false, solution: inout [Double]) async throws -> Int {
        var matrix = SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: 1, entries: [(0, 0)]))
        var rhs = [1.0]
        var solver: any LinearSolver = InjectedSolver(counts: counts, correction: correction,
            cancellation: cancelDuringCorrection ? cancellation : nil)
        var newton = NewtonRaphsonSolver(config: .init(abstol: 1e-15, reltol: 1e-12,
            vntol: 1e-12, maxIterations: 1, gmin: 0))
        newton.executionBudget = budget
        return try await newton.solve(initialGuess: [1], solution: &solution,
            matrix: &matrix, rhs: &rhs, devices: [], variableMap: [.nodeVoltage(Node(id: 1)): 0],
            solver: &solver, stampFunction: { stamper, _ in
                stamper.stampMatrix(0, 0, 1); stamper.stampRHS(0, 1)
            }, observer: nil, analysisID: AnalysisID(), cancellation: cancellation)
    }

    @Test("Refinement charges actual solves and work without extra Newton iterations")
    func exactBudgetAndSolveQuota() async throws {
        let baseline = try TransientExecutionBudget(limits: limits(), dimension: 1, nonZeroCount: 1, deviceCount: 0)
        var solution = [0.0]
        _ = try await smallSolve(budget: baseline, counts: Counts(), solution: &solution)
        #expect(solution == [1])
        #expect(baseline.statistics.solveAttempts == 2)
        #expect(baseline.statistics.newtonIterations == 1)
        let work = baseline.statistics.workUnits
        for cap in [work, work - 1] {
            let budget = try TransientExecutionBudget(limits: limits(work: cap), dimension: 1, nonZeroCount: 1, deviceCount: 0)
            do {
                _ = try await smallSolve(budget: budget, counts: Counts(), solution: &solution)
                #expect(cap == work)
            } catch TransientExecutionError.limitExceeded(let resource, _, _) {
                #expect(cap == work - 1 && resource == "workUnits")
            }
        }
        let counts = Counts()
        let limited = try TransientExecutionBudget(limits: limits(solves: 1), dimension: 1, nonZeroCount: 1, deviceCount: 0)
        do {
            _ = try await smallSolve(budget: limited, counts: counts, solution: &solution)
            Issue.record("Correction must be admitted before the injected solver is invoked")
        } catch TransientExecutionError.limitExceeded(let resource, _, _) {
            #expect(resource == "solveAttempts")
            #expect(counts.snapshot.solves == 1)
            #expect(limited.statistics.solveAttempts == 1)
        }
    }

    @Test("Unchanged or worse corrections retain the best raw solution", arguments: [0.0, -1.0])
    func noImprovement(_ correction: Double) async throws {
        let budget = try TransientExecutionBudget(limits: limits(), dimension: 1, nonZeroCount: 1, deviceCount: 0)
        let counts = Counts()
        var solution = [1.0]
        do {
            _ = try await smallSolve(budget: budget, counts: counts, correction: correction, solution: &solution)
            Issue.record("The strict physical gate must reject the unchanged bad solution")
        } catch AnalysisError.convergenceFailure(let iterations, _) {
            #expect(iterations == 1)
            #expect(solution == [0.5])
            #expect(counts.snapshot.solves == 2)
        }
    }

    @Test("Cancellation after a correction does not publish the candidate")
    func correctionCancellation() async throws {
        let budget = try TransientExecutionBudget(limits: limits(), dimension: 1, nonZeroCount: 1, deviceCount: 0)
        let counts = Counts()
        var solution = [1.0]
        do {
            _ = try await smallSolve(budget: budget, counts: counts,
                cancelDuringCorrection: true, solution: &solution)
            Issue.record("Expected cancellation before candidate publication")
        } catch AnalysisError.cancelled {
            #expect(solution == [1])
            #expect(counts.snapshot.solves == 2)
        }
    }

    @Test("Non-finite refinement corrections fail explicitly")
    func nonFiniteCorrection() async throws {
        let budget = try TransientExecutionBudget(limits: limits(), dimension: 1, nonZeroCount: 1, deviceCount: 0)
        var solution = [1.0]
        do {
            _ = try await smallSolve(budget: budget, counts: Counts(), correction: .infinity, solution: &solution)
            Issue.record("Expected a non-finite correction failure")
        } catch AnalysisError.nonFiniteSolution(let iteration, let index, let value) {
            #expect(iteration == 0 && index == 0 && value.isInfinite)
            #expect(solution == [1])
        }
    }

    private struct FixedSolver: LinearSolver {
        let value: [Double]
        mutating func factorize(matrix: SparseMatrix) throws {}
        func solve(rhs: [Double]) throws -> [Double] { value }
    }
}
