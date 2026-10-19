import Accelerate
import Testing
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Swift Newton vector arithmetic", .timeLimit(.minutes(1)))
struct NewtonSwiftVectorTests {
    @Test("Signed update magnitudes preserve adaptive damping and interpolation",
          arguments: [3, 8, 9, 17])
    func signedMagnitudeDamping(_ dimension: Int) async throws {
        var first = [Double](repeating: 0, count: dimension)
        var second = first, expected = first
        first[0] = 2; first[dimension - 2] = -4; first[dimension - 1] = 1
        second[0] = 18; second[dimension - 2] = -12; second[dimension - 1] = 5
        expected[0] = 6; expected[dimension - 2] = -6; expected[dimension - 1] = 2
        var matrix = try diagonalMatrix(dimension: dimension)
        var rhs = [Double](repeating: 0, count: dimension)
        var solution = rhs
        var solver: any LinearSolver = SparseLUSolver()
        let observer = try BufferingObserver(capacity: 16)
        do {
            _ = try await NewtonRaphsonSolver(config: .init(
                reltol: 0, vntol: 1e-12, maxIterations: 2, gmin: 0
            )).solve(initialGuess: rhs, solution: &solution, matrix: &matrix, rhs: &rhs,
                devices: [], variableMap: variableMap(dimension: dimension), solver: &solver,
                stampFunction: { stamper, state in
                    let target = state.variables[0] == 0 ? first : second
                    for i in target.indices {
                        stamper.stampMatrix(i, i, 1)
                        stamper.stampRHS(i, target[i])
                    }
                }, observer: EventDispatcher(observers: [observer]), analysisID: .init(),
                cancellation: CancellationToken())
            Issue.record("Two changing iterates must not publish convergence")
        } catch AnalysisError.convergenceFailure(let iterations, _) {
            #expect(iterations == 2)
        }
        #expect(solution == expected)
        let updates = observer.events.compactMap { event -> NewtonResultInfo? in
            if case .newtonIterationFinished(let info) = event { return info }
            return nil
        }
        #expect(updates.count == 2)
        #expect(updates.map(\.damping) == [1, 0.25])
        #expect(updates.map(\.residualNorm) == [4, 4])
        #expect(updates.allSatisfy { !$0.converged })
    }

    @Test("Finite vectors retain the final coordinate and original equation gate",
          arguments: [1, 7, 8, 9, 15, 16, 17, 455, 847])
    func finiteVectorLengths(_ dimension: Int) async throws {
        var target = (0..<dimension).map { Double($0 % 7) * 0.125 - 0.5 }
        target[dimension - 1] = -8
        let initial = [Double](repeating: 0, count: dimension)
        var solution = initial
        var matrix = try diagonalMatrix(dimension: dimension)
        var rhs = initial
        var solver: any LinearSolver = SparseLUSolver()
        let observer = try BufferingObserver(capacity: 16)
        let iterations = try await NewtonRaphsonSolver(config: .init(
            reltol: 0, vntol: 1e-12, maxIterations: 3, gmin: 0
        )).solve(initialGuess: initial, solution: &solution, matrix: &matrix, rhs: &rhs,
            devices: [], variableMap: variableMap(dimension: dimension), solver: &solver,
            stampFunction: { stamper, _ in
                for i in target.indices {
                    stamper.stampMatrix(i, i, 1)
                    stamper.stampRHS(i, target[i])
                }
            }, observer: EventDispatcher(observers: [observer]), analysisID: .init(),
            cancellation: CancellationToken())
        #expect(iterations == 2)
        #expect(solution == target)
        let updates = observer.events.compactMap { event -> NewtonResultInfo? in
            if case .newtonIterationFinished(let info) = event { return info }
            return nil
        }
        #expect(updates.map(\.residualNorm) == [8, 0])
        #expect(updates.map(\.damping) == [1, 1])
        #expect(updates.last?.converged == true)
        var residual = initial
        try matrix.checkedResidual(vector: solution, rhs: rhs, into: &residual)
        #expect(residual.allSatisfy { $0 == 0 })
    }

    @Test("Unit damping matches the retained Accelerate oracle at finite and overflow boundaries",
          arguments: [false, true])
    func unitDampingOracle(_ overflow: Bool) async throws {
        // Accelerate is a test-only oracle; production vector execution is Swift.
        let previous = [overflow ? Double.greatestFiniteMagnitude : 8]
        let raw = [overflow ? -Double.greatestFiniteMagnitude : -8]
        var damping = 1.0
        var reference = [Double.nan]
        vDSP_vintbD(previous, 1, raw, 1, &damping, &reference, 1, 1)

        var solution = [0.0]
        var matrix = try diagonalMatrix(dimension: 1)
        var rhs = [0.0]
        var solver: any LinearSolver = SparseLUSolver()
        var failure: AnalysisError?
        do {
            _ = try await NewtonRaphsonSolver(config: .init(
                reltol: 0, vntol: 1e-12, maxIterations: 1, gmin: 0
            )).solve(initialGuess: previous, solution: &solution, matrix: &matrix, rhs: &rhs,
                devices: [], variableMap: variableMap(dimension: 1), solver: &solver,
                stampFunction: { stamper, _ in
                    stamper.stampMatrix(0, 0, 1)
                    stamper.stampRHS(0, raw[0])
                }, observer: nil, analysisID: .init(), cancellation: CancellationToken())
        } catch let error as AnalysisError {
            failure = error
        }

        if reference[0].isFinite {
            #expect(solution[0] == reference[0])
            if let failure {
                guard case .convergenceFailure = failure else { throw failure }
            }
        } else {
            guard case .some(.nonFiniteSolution(let iteration, let index, let value)) = failure else {
                Issue.record("Nonfinite interpolation must fail before publishing a result")
                return
            }
            #expect(iteration == 0 && index == 0)
            #expect(!value.isFinite)
            #expect(value.isNaN == reference[0].isNaN)
            if !value.isNaN { #expect(value.sign == reference[0].sign) }
        }
    }

    @Test("Nonfinite interpolation is rejected in a SIMD block or scalar tail",
          arguments: [0, 7, 8, 15, 16])
    func overflowLane(_ index: Int) async throws {
        let dimension = index + 1
        var previous = [Double](repeating: 1, count: dimension)
        var raw = [Double](repeating: 2, count: dimension)
        previous[index] = .greatestFiniteMagnitude
        raw[index] = -.greatestFiniteMagnitude
        var solution = [Double](repeating: 0, count: dimension)
        var rhs = solution
        var matrix = try diagonalMatrix(dimension: dimension)
        var solver: any LinearSolver = SparseLUSolver()
        do {
            _ = try await NewtonRaphsonSolver(config: .init(
                reltol: 0, vntol: 1e-12, maxIterations: 1, gmin: 0
            )).solve(initialGuess: previous, solution: &solution, matrix: &matrix, rhs: &rhs,
                devices: [], variableMap: variableMap(dimension: dimension), solver: &solver,
                stampFunction: { stamper, _ in
                    for i in raw.indices {
                        stamper.stampMatrix(i, i, 1)
                        stamper.stampRHS(i, raw[i])
                    }
                }, observer: nil, analysisID: .init(), cancellation: CancellationToken())
            Issue.record("Overflow must not publish a Newton result")
        } catch AnalysisError.nonFiniteSolution(let iteration, let variableIndex, let value) {
            #expect(iteration == 0 && variableIndex == index)
            #expect(value == -.infinity)
        }
    }

    @Test("Subnormal updates and zero lanes survive SIMD blocks and tails",
          arguments: [8, 9, 16, 17])
    func subnormalAndZeroLanes(_ dimension: Int) async throws {
        let initial = [Double](repeating: 0, count: dimension)
        var target = initial
        target[0] = -.leastNonzeroMagnitude
        target[dimension - 1] = .leastNonzeroMagnitude
        var solution = initial, rhs = initial
        var matrix = try diagonalMatrix(dimension: dimension)
        var solver: any LinearSolver = SparseLUSolver()
        _ = try await NewtonRaphsonSolver(config: .init(
            reltol: 0, vntol: 1e-12, maxIterations: 2, gmin: 0
        )).solve(initialGuess: initial, solution: &solution, matrix: &matrix, rhs: &rhs,
            devices: [], variableMap: variableMap(dimension: dimension), solver: &solver,
            stampFunction: { stamper, _ in
                for i in target.indices {
                    stamper.stampMatrix(i, i, 1)
                    stamper.stampRHS(i, target[i])
                }
            }, observer: nil, analysisID: .init(), cancellation: CancellationToken())
        for i in target.indices { #expect(solution[i].bitPattern == target[i].bitPattern) }
    }

    @Test("Compensated corrections preserve low components across 32-value groups and tails",
          arguments: [31, 32, 33, 63, 64, 65])
    func compensatedBlockTails(_ dimension: Int) async throws {
        let initial = [Double](repeating: 0.5, count: dimension)
        var high = initial, low = [Double](repeating: 0, count: dimension)
        var rhs = low
        var matrix = try diagonalMatrix(dimension: dimension)
        var solver: any LinearSolver = SparseLUSolver()
        let observer = try BufferingObserver(capacity: 100)
        let row = try DCEquationRowPolicy(kind: .thermalPotential,
            variableAbsoluteTolerance: 1e-9, equationAbsoluteTolerance: 1e-12)
        let policy = try DCEquationPolicy(rows: Array(repeating: row, count: dimension))
        _ = try await NewtonRaphsonSolver(config: .init(reltol: 0, maxIterations: 20, gmin: 0),
            equationPolicy: policy, physicalResidualEncloser: VectorSubULPResidual()).solve(
                initialGuess: initial, initialLowComponents: low,
                solution: &high, solutionLowComponents: &low, matrix: &matrix, rhs: &rhs,
                devices: [], variableMap: variableMap(dimension: dimension), solver: &solver,
                stampFunction: { stamper, state in
                    let last = try state.checkedCompensatedValue(at: dimension - 1)
                    let first = last.high == 0.5 && last.low == 0
                    for i in 0..<dimension { stamper.stampMatrix(i, i, 0x1p20 * (first ? 100 : 1)) }
                }, observer: EventDispatcher(observers: [observer]), analysisID: .init(),
                cancellation: CancellationToken())
        for i in 0..<dimension {
            #expect(high[i] == 0.5)
            #expect(abs(low[i] - VectorSubULPResidual.targetLow(row: i, count: dimension)) <= 0x1p-90)
        }
        #expect(observer.events.contains { event in
            if case .newtonIterationFinished(let info) = event { return info.damping < 1 }
            return false
        })
    }

    private func diagonalMatrix(dimension: Int) throws -> SparseMatrix {
        SparseMatrix(structure: try SparseStructure.fromTriplets(dimension: dimension,
            entries: (0..<dimension).map { ($0, $0) }))
    }

    private func variableMap(dimension: Int) -> [MNAVariable: Int] {
        Dictionary(uniqueKeysWithValues: (0..<dimension).map { (.nodeVoltage(Node(id: $0 + 1)), $0) })
    }
}

private struct VectorSubULPResidual: NonlinearPhysicalResidualEnclosing {
    static func targetLow(row: Int, count: Int) -> Double {
        row == count - 1 ? 0x1p-56 : (row.isMultiple(of: 2) ? 0x1p-58 : -0x1p-58)
    }

    func accumulateResidualEnclosure(state: SolutionState,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        for i in state.variables.indices {
            let target = try CompensatedValue(high: 0.5, low: Self.targetLow(row: i, count: state.variables.count))
            let offset = try CompensatedEnclosure(center: state.checkedCompensatedValue(at: i))
                .subtracting(CompensatedEnclosure(center: target))
                .multiplied(by: CompensatedEnclosure(center: CompensatedValue(high: 0x1p20)))
            add(i, offset.center, offset.radius)
        }
    }
}
