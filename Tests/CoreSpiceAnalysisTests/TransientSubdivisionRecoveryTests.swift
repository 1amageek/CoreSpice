import Testing
import Synchronization
import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Bootstrap subdivision recovery", .timeLimit(.minutes(1)))
struct TransientSubdivisionRecoveryTests {
    private func fixture(phase: SubdivisionPrecisionProbe.Phase = .quarter,
                         action: SubdivisionPrecisionProbe.Action = .nonconvergence,
                         initialFailure: Bool = false) throws -> (ExecutionPlan, [any BoundDevice], SubdivisionPrecisionProbe, Node) {
        var netlist = Netlist()
        _ = netlist.node("in")
        let output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["pwl": .realVector([0, 0, 4, 4])])
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["in", "out"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "C", typeName: "capacitor", nodes: ["out", "0"], parameters: ["c": .real(1)])
        let (plan, original) = try CircuitFactory.compile(netlist)
        let probe = SubdivisionPrecisionProbe(base: original[2], phase: phase, action: action, initialFailure: initialFailure)
        var devices = original
        devices[2] = probe
        return (plan, devices, probe, output)
    }

    private func config(maximumSolves: Int = 100) -> TransientConfig {
        .init(stopTime: 2, executionLimits: .init(maximumAcceptedSteps: 16, maximumSolveAttempts: maximumSolves,
            maximumNewtonIterations: 300, maximumSavedScalars: 1_000, maximumMatrixDimension: 8,
            maximumWorkUnits: 1_000_000, maximumBreakpoints: 8), maxTimeStep: 1, initialTimeStep: 1,
            minTimeStep: 1, useInitialConditions: true, gminSteppingThreshold: .max)
    }
    private var convergence: ConvergenceConfig { .init(reltol: 1e-12, vntol: 0.2, maxIterations: 2, gmin: 0) }

    @Test(arguments: [SubdivisionPrecisionProbe.Phase.quarter, .half])
    fileprivate func failedSubdivisionUsesUnchangedFullIntervalAndCommitsOnlyBE(_ phase: SubdivisionPrecisionProbe.Phase) async throws {
        let (plan, devices, probe, output) = try fixture(phase: phase)
        let events = try BufferingObserver(capacity: 100)
        let result = try await TransientAnalysis(config: config(), convergenceConfig: convergence).run(
            plan: plan, devices: devices, solver: SparseLUSolver(), observer: EventDispatcher(observers: [events]),
            cancellation: probe.cancellation)
        #expect(result.timePoints == [0, 1, 2])
        #expect(abs(try result.voltage(at: output, timeIndex: 1) - 0.5) < 1e-12)
        #expect(abs(try result.voltage(at: output, timeIndex: 2) - 1.25) < 1e-12)
        #expect(result.acceptedSteps.allSatisfy { $0.timeStep == 1 && $0.method == .backwardEuler })
        #expect(probe.snapshot.trapezoidalTrials > 0)
        #expect(probe.snapshot.commits == 2 && probe.snapshot.ends == 1)
        #expect(!probe.snapshot.historyMismatch)
        #expect(result.rejectedSteps == 1)
        let statistics = try #require(result.executionStatistics)
        #expect(statistics.solveAttempts == (phase == .quarter ? 6 : 7))
        #expect(statistics.newtonIterations == 2 * statistics.solveAttempts)
        let rejection = try #require(events.events.compactMap { event -> TimeStepRejectInfo? in
            if case .timeStepRejected(let info) = event { return info }; return nil
        }.first)
        #expect(rejection.rejectedStep == 1 && rejection.newStep == 1)
        #expect(rejection.reason.contains("same-interval BE/TR"))
    }

    @Test func initialSubdivisionFailureCannotInventAcceptedDerivativeHistory() async throws {
        let (plan, devices, probe, _) = try fixture(initialFailure: true)
        do {
            _ = try await TransientAnalysis(config: config(), convergenceConfig: convergence).run(
                plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: probe.cancellation)
            Issue.record("Missing accepted derivative history must not recover")
        } catch let error as AnalysisError {
            guard case .timestepTooSmall(let step) = error else { throw error }
            #expect(step == 0.5)
        }
        #expect(probe.snapshot.commits == 0 && probe.snapshot.trapezoidalTrials == 0 && probe.snapshot.ends == 1)
    }

    @Test(arguments: [SubdivisionPrecisionProbe.Action.deviceFailure, .cancellation, .pairNonconvergence])
    fileprivate func terminalErrorsAndFailedPairNeverCommitTheSecondStep(_ action: SubdivisionPrecisionProbe.Action) async throws {
        let (plan, devices, probe, _) = try fixture(action: action)
        do {
            _ = try await TransientAnalysis(config: config(), convergenceConfig: convergence).run(
                plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: probe.cancellation)
            Issue.record("The second step must fail")
        } catch let error as SubdivisionProbeFailure {
            #expect(action == .deviceFailure && error == .device)
            #expect(probe.snapshot.trapezoidalTrials == 0)
        } catch let error as AnalysisError {
            switch error {
            case .cancelled: #expect(action == .cancellation && probe.snapshot.trapezoidalTrials == 0)
            case .timestepTooSmall(let step): #expect(action == .pairNonconvergence && step == 0.5)
            default: throw error
            }
        }
        #expect(probe.snapshot.commits == 1 && probe.snapshot.ends == 1)
        #expect(!probe.snapshot.historyMismatch)
    }

    @Test func recoveryCannotBypassTheExistingSolveQuota() async throws {
        let (plan, devices, probe, _) = try fixture()
        do {
            _ = try await TransientAnalysis(config: config(maximumSolves: 4), convergenceConfig: convergence).run(
                plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: probe.cancellation)
            Issue.record("The embedded trial must require another admitted solve")
        } catch let error as TransientExecutionError {
            #expect(error == .limitExceeded(resource: "solveAttempts", limit: 4, requested: 5))
        }
        #expect(probe.snapshot.commits == 1 && probe.snapshot.ends == 1)
    }
}

private enum SubdivisionProbeFailure: Error { case device }

/// Emulates a recoverable precision floor for only the smaller trial intervals of an actual RC circuit.
private final class SubdivisionPrecisionProbe: TransientSessionDevice {
    enum Phase: Sendable { case quarter, half }
    enum Action: Sendable { case nonconvergence, deviceFailure, cancellation, pairNonconvergence }
    struct State: Sendable {
        var accepted: [Double] = []
        var commits = 0
        var ends = 0
        var trapezoidalTrials = 0
        var historyMismatch = false
        var lastStep = 0.0
        var lastMethod = IntegrationMethod.backwardEuler
    }
    private let state = Mutex(State())
    let base: any BoundDevice
    let phase: Phase
    let action: Action
    let initialFailure: Bool
    let cancellation = CancellationToken()
    init(base: any BoundDevice, phase: Phase, action: Action, initialFailure: Bool) {
        self.base = base; self.phase = phase; self.action = action; self.initialFailure = initialFailure
    }
    var instance: Instance { base.instance }
    var snapshot: State { state.withLock { $0 } }
    func beginTransientSession(initialState: SolutionState) throws {
        try (base as? any TransientSessionDevice)?.beginTransientSession(initialState: initialState)
        state.withLock { $0.accepted = initialState.variables }
    }
    func endTransientSession() {
        (base as? any TransientSessionDevice)?.endTransientSession()
        state.withLock { $0.ends += 1 }
    }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try base.stampAC(into: &stamper, state: state, omega: omega)
    }
    func stampTransient(into stamper: inout MatrixStamper, state solution: SolutionState, integration: IntegrationState) throws {
        let fail = state.withLock { owner in
            owner.historyMismatch = owner.historyMismatch || solution.previousVariables != owner.accepted
            owner.lastStep = integration.timeStep; owner.lastMethod = integration.method
            if integration.method == .trapezoidal { owner.trapezoidalTrials += 1 }
            return (owner.commits > 0 || initialFailure) && integration.method == .backwardEuler
                && integration.timeStep == (phase == .quarter ? 0.25 : 0.5)
        }
        if fail && action == .deviceFailure { throw SubdivisionProbeFailure.device }
        if fail && action == .cancellation { cancellation.cancel() }
        try base.stampTransient(into: &stamper, state: solution, integration: integration)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let fail = self.state.withLock { owner in
            guard owner.commits > 0 || initialFailure else { return false }
            return (owner.lastMethod == .backwardEuler && owner.lastStep == (phase == .quarter ? 0.25 : 0.5))
                || (action == .pairNonconvergence && owner.lastMethod == .trapezoidal)
        }
        return fail ? .notConverged(maxDelta: 1, deviceName: instance.name) : base.checkConvergence(state: state, previousState: previousState)
    }
    func commitTransientStep(state solution: SolutionState, integration: IntegrationState) throws {
        try (base as? any TransientStateCommittingDevice)?.commitTransientStep(state: solution, integration: integration)
        state.withLock { $0.accepted = solution.variables; $0.commits += 1 }
    }
}
