import Testing
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Compensated Newton", .timeLimit(.minutes(1)))
struct CompensatedNewtonTests {
    @Test func subULPCorrectionSurvivesActualAdaptiveDamping() async throws {
        let observer = try BufferingObserver(capacity: 100)
        let result = try await solve(encloser: SubULPLinearResidual(), observer: observer)
        #expect(result.0 == 0.5)
        #expect(abs(result.1 - 0x1p-56) <= 0x1p-90)
        #expect(observer.events.contains { event in
            if case .newtonIterationFinished(let info) = event { return info.damping < 1 }; return false
        })
    }

    @Test func radiusCannotCertifyAZeroCenter() async throws {
        do {
            _ = try await solve(encloser: BadEnclosedResidual(mode: .radius))
            Issue.record("An uncertain zero center must not converge")
        } catch let error as NonlinearPhysicalResidualError {
            guard case .insufficientPrecision(let row, let radius, let tolerance) = error else { throw error }
            #expect(row == 0 && radius >= 2e-12 && tolerance == 1e-12)
        }
    }

    @Test(arguments: [BadEnclosedResidual.Mode.invalidRow, .invalidRadius, .callback, .cancel])
    fileprivate func invalidEnclosuresAndCancellationPropagate(_ mode: BadEnclosedResidual.Mode) async throws {
        let cancellation = CancellationToken()
        do {
            _ = try await solve(encloser: BadEnclosedResidual(mode: mode, cancellation: cancellation), cancellation: cancellation)
            Issue.record("Invalid precision evaluation must fail")
        } catch let error as NonlinearPhysicalResidualError {
            #expect(mode == .invalidRow)
            #expect(error == .invalidRow(row: 1, dimension: 1))
        } catch let error as NumericalStateError {
            #expect(mode == .invalidRadius)
            guard case .invalidRadius(let value) = error else { throw error }; #expect(value.isNaN)
        } catch let error as CompensatedFixtureFailure { #expect(mode == .callback && error == .callback) }
        catch let error as AnalysisError {
            #expect(mode == .cancel)
            guard case .cancelled = error else { throw error }
        }
    }

    private func solve(encloser: any NonlinearPhysicalResidualEnclosing, observer: BufferingObserver? = nil,
                       cancellation: CancellationToken = .init()) async throws -> (Double, Double) {
        let structure = try SparseStructure(dimension: 1, rowPointers: [0, 1], columnIndices: [0])
        var matrix = SparseMatrix(structure: structure)
        var rhs = [0.0], high = [0.0], low = [0.0]
        var solver: any LinearSolver = SparseLUSolver()
        let policy = try DCEquationPolicy(rows: [.init(kind: .thermalPotential,
            variableAbsoluteTolerance: 1e-9, equationAbsoluteTolerance: 1e-12)])
        _ = try await NewtonRaphsonSolver(config: .init(reltol: 0, maxIterations: 20, gmin: 0),
            equationPolicy: policy, physicalResidualEncloser: encloser).solve(
                initialGuess: [0.5], initialLowComponents: [0], solution: &high, solutionLowComponents: &low,
                matrix: &matrix, rhs: &rhs, devices: [], variableMap: [.nodeVoltage(Node(id: 1)): 0], solver: &solver,
                stampFunction: { stamper, state in
                    let value = try state.checkedCompensatedValue(at: 0)
                    let first = value.high == 0.5 && value.low == 0
                    stamper.stampMatrix(0, 0, 0x1p20 * (first ? 100 : 1))
                }, observer: observer.map { EventDispatcher(observers: [$0]) },
                analysisID: .init(), cancellation: cancellation)
        return (high[0], low[0])
    }
}

private struct SubULPLinearResidual: NonlinearPhysicalResidualEnclosing {
    func accumulateResidualEnclosure(state: SolutionState, add: (Int, CompensatedValue, Double) -> Void) throws {
        let offset = try CompensatedEnclosure(center: state.checkedCompensatedValue(at: 0))
            .subtracting(CompensatedEnclosure(center: CompensatedValue(high: 0.5, low: 0x1p-56)))
            .multiplied(by: CompensatedEnclosure(center: CompensatedValue(high: 0x1p20)))
        add(0, offset.center, offset.radius)
    }
}

private enum CompensatedFixtureFailure: Error { case callback }
private struct BadEnclosedResidual: NonlinearPhysicalResidualEnclosing {
    enum Mode: Sendable { case radius, invalidRow, invalidRadius, callback, cancel }
    let mode: Mode
    var cancellation = CancellationToken()
    func accumulateResidualEnclosure(state: SolutionState, add: (Int, CompensatedValue, Double) -> Void) throws {
        switch mode {
        case .radius: add(0, .zero, 2e-12)
        case .invalidRow: add(1, .zero, 0)
        case .invalidRadius: add(0, .zero, .nan)
        case .callback: throw CompensatedFixtureFailure.callback
        case .cancel: cancellation.cancel()
        }
    }
}
