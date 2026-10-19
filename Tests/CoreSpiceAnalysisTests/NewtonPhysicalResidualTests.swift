import Testing
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Original-residual Newton corrections", .timeLimit(.minutes(1)))
struct NewtonPhysicalResidualTests {
    private func solve(evaluator: (any NonlinearPhysicalResidualEvaluating)?, gmin: Double = 0,
                       cancellation: CancellationToken = .init()) async throws -> [Double] {
        let structure = try SparseStructure(dimension: 2, rowPointers: [0, 2, 3], columnIndices: [0, 1, 0])
        var matrix = SparseMatrix(structure: structure)
        var rhs = [0.0, 0.0]
        var solver: any LinearSolver = SparseLUSolver()
        let policy = try DCEquationPolicy(rows: [
            .init(kind: .electricalPotential, variableAbsoluteTolerance: 1e-12, equationAbsoluteTolerance: 1e-12),
            .init(kind: .electricalFlow, variableAbsoluteTolerance: 1e-12, equationAbsoluteTolerance: 1e-12)
        ])
        let result = try await NewtonRaphsonSolver(config: .init(reltol: 1e-10, maxIterations: 8, gmin: gmin),
            equationPolicy: policy, physicalResidualEvaluator: evaluator).solve(initialGuess: [1, 0],
                matrix: &matrix, rhs: &rhs, devices: [],
                variableMap: [.nodeVoltage(Node(id: 1)): 0, .branchCurrent(Branch(id: 0)): 1], solver: &solver,
                stampFunction: { stamper, _ in
                    stamper.stampMatrix(0, 0, 1e12)
                    stamper.stampMatrix(0, 1, 1)
                    stamper.stampMatrix(1, 0, 1)
                    stamper.stampRHS(0, 1e12 + 1e-6)
                    stamper.stampRHS(1, 1)
                }, observer: nil, analysisID: .init(), cancellation: cancellation)
        return result.solution
    }

    @Test func directCorrectionRecoversCurrentLostInFullSolutionRHS() async throws {
        let rounded = try await solve(evaluator: nil)
        #expect(rounded == [1, 0])
        #expect(abs(rounded[1] - 1e-6) > 1e-12)
        let direct = try await solve(evaluator: CoupledPhysicalResidual())
        #expect(direct[0] == 1)
        #expect(abs(direct[1] - 1e-6) <= 1e-12)
    }

    @Test func directResidualIncludesOnlyEligibleRegularization() async throws {
        let direct = try await solve(evaluator: CoupledPhysicalResidual(), gmin: 1e-3)
        #expect(direct[0] == 1)
        #expect(abs(direct[1] - (1e-6 - 1e-3)) <= 1e-12)
    }

    @Test(arguments: BadPhysicalResidual.Mode.allCases)
    fileprivate func invalidOriginalResidualCannotConverge(_ mode: BadPhysicalResidual.Mode) async throws {
        let cancellation = CancellationToken()
        do {
            _ = try await solve(evaluator: BadPhysicalResidual(mode: mode, cancellation: cancellation), cancellation: cancellation)
            Issue.record("Invalid original residual must not converge")
        } catch let error as NonlinearPhysicalResidualError {
            switch (mode, error) {
            case (.invalidRow, .invalidRow(let row, let dimension)): #expect(row == 2 && dimension == 2)
            case (.nonfinite, .nonfiniteContribution(let row, let value)): #expect(row == 0 && value.isNaN)
            default: Issue.record("Unexpected physical residual failure: \(error)")
            }
        } catch let error as OriginalResidualFailure {
            #expect(mode == .callbackFailure && error == .callback)
        } catch let error as AnalysisError {
            #expect(mode == .cancellation)
            guard case .cancelled = error else { Issue.record("Unexpected failure: \(error)"); return }
        }
    }
}

private struct CoupledPhysicalResidual: NonlinearPhysicalResidualEvaluating {
    func accumulateResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        let voltage = try state.checkedValue(at: 0)
        let current = try state.checkedValue(at: 1)
        add(0, 1e12 * (voltage - 1))
        add(0, current - 1e-6)
        add(1, voltage - 1)
    }
}

private enum OriginalResidualFailure: Error { case callback }

private struct BadPhysicalResidual: NonlinearPhysicalResidualEvaluating {
    enum Mode: Sendable, CaseIterable { case invalidRow, nonfinite, callbackFailure, cancellation }
    let mode: Mode
    let cancellation: CancellationToken
    func accumulateResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        switch mode {
        case .invalidRow: add(2, 1)
        case .nonfinite: add(0, .nan)
        case .callbackFailure: throw OriginalResidualFailure.callback
        case .cancellation: cancellation.cancel()
        }
    }
}
