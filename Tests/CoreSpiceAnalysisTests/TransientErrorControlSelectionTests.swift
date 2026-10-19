import Testing
import Synchronization
import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Transient error-control selection", .timeLimit(.minutes(1)))
struct TransientErrorControlSelectionTests {
    private func fixture() throws -> (ExecutionPlan, AlgebraicStepProbe, Node) {
        var netlist = Netlist()
        let output = netlist.node("out")
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["out", "0"], parameters: ["r": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let index = try #require(plan.topology.variableMap[.nodeVoltage(output)])
        return (plan, AlgebraicStepProbe(base: devices[0], index: index), output)
    }

    private func config() -> TransientConfig {
        .init(stopTime: 0.2, executionLimits: .init(maximumAcceptedSteps: 16,
            maximumSolveAttempts: 100, maximumNewtonIterations: 300, maximumSavedScalars: 1_000,
            maximumMatrixDimension: 4, maximumWorkUnits: 1_000_000, maximumBreakpoints: 8),
            maxTimeStep: 0.2, initialTimeStep: 0.2, minTimeStep: 0.2,
            preferredMethod: .backwardEuler, useInitialConditions: true)
    }

    @Test(arguments: [false, true])
    func algebraicJumpUsesExplicitSelectionWithoutSkippingPhysicalValidation(_ explicitEmpty: Bool) async throws {
        let (plan, probe, output) = try fixture()
        do {
            let result = try await TransientAnalysis(config: config(), convergenceConfig: .init(gmin: 0),
                physicalResidualValidator: probe, errorControlVariables: explicitEmpty ? [] : nil).run(
                    plan: plan, devices: [probe], solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            #expect(explicitEmpty)
            #expect(try result.voltage(at: output, timeIndex: 0) == 0)
            #expect(try result.voltage(at: output, timeIndex: 1) == 1)
            #expect(result.timePoints == [0, 0.2])
            #expect(probe.snapshot.validations == 1)
            #expect(probe.snapshot.commits == 1)
        } catch let error as AnalysisError {
            #expect(!explicitEmpty)
            guard case .timestepTooSmall = error else { Issue.record("Unexpected failure: \(error)"); return }
            #expect(probe.snapshot.commits == 0)
        }
    }

    @Test func emptySelectionStillPropagatesPhysicalFailureBeforeCommit() async throws {
        let (plan, probe, _) = try fixture()
        probe.rejectPhysicalValidation()
        do {
            _ = try await TransientAnalysis(config: config(), convergenceConfig: .init(gmin: 0),
                physicalResidualValidator: probe, errorControlVariables: []).run(plan: plan, devices: [probe],
                    solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Physical validation must not be bypassed")
        } catch let error as AlgebraicStepFailure { #expect(error == .physical) }
        #expect(probe.snapshot.validations == 1)
        #expect(probe.snapshot.commits == 0)
    }

    @Test(arguments: [MNAVariable.nodeVoltage(.ground), .nodeVoltage(Node(id: 99)), .branchCurrent(Branch(id: 99))])
    func unknownIdentityFailsBeforeStamping(_ variable: MNAVariable) async throws {
        let (plan, probe, _) = try fixture()
        do {
            _ = try await TransientAnalysis(config: config(), errorControlVariables: [variable]).run(
                plan: plan, devices: [probe], solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Unknown error-control identity must fail admission")
        } catch let error as TransientExecutionError { #expect(error == .unknownErrorControlVariable(variable)) }
        #expect(probe.snapshot.stamps == 0)
        #expect(probe.snapshot.commits == 0)
    }
}

private enum AlgebraicStepFailure: Error { case physical }

/// A Q=0 algebraic equation whose target jumps; no integration history is approximated.
private final class AlgebraicStepProbe: TransientStateCommittingDevice, TransientPhysicalResidualValidating {
    struct State: Sendable { var stamps = 0; var commits = 0; var validations = 0; var rejectPhysical = false }
    private let state = Mutex(State())
    let base: any BoundDevice
    let index: Int
    init(base: any BoundDevice, index: Int) { self.base = base; self.index = index }
    var instance: Instance { base.instance }
    var snapshot: State { state.withLock { $0 } }
    func rejectPhysicalValidation() { state.withLock { $0.rejectPhysical = true } }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        self.state.withLock { $0.stamps += 1 }
        try base.stampDC(into: &stamper, state: state)
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try base.stampAC(into: &stamper, state: state, omega: omega)
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        self.state.withLock { $0.stamps += 1 }
        stamper.stampMatrix(index, index, 1)
        stamper.stampRHS(index, integration.currentTime >= 0.1 ? 1 : 0)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
    func validate(state: SolutionState, integration: IntegrationState) throws {
        let reject = self.state.withLock { $0.validations += 1; return $0.rejectPhysical }
        let target = integration.currentTime >= 0.1 ? 1.0 : 0.0
        guard !reject, abs(try state.checkedValue(at: index) - target) < 1e-12 else { throw AlgebraicStepFailure.physical }
    }
    func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        self.state.withLock { $0.commits += 1 }
    }
}
