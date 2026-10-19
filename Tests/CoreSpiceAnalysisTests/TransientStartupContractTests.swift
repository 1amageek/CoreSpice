import Testing
import Synchronization
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Checked transient startup", .timeLimit(.minutes(1)))
struct TransientStartupContractTests {
    private func limits() -> TransientExecutionLimits {
        .init(maximumAcceptedSteps: 10_000, maximumSolveAttempts: 50_000,
            maximumNewtonIterations: 100_000, maximumSavedScalars: 100_000,
            maximumMatrixDimension: 8, maximumWorkUnits: 100_000_000, maximumBreakpoints: 16)
    }

    private func fixture(token: CancellationToken? = nil) throws -> (ExecutionPlan, [any BoundDevice], StartupHistoryProbe, Node) {
        var netlist = Netlist()
        _ = netlist.node("in")
        let output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["pwl": .realVector([0, 0, 0.3, 0, 0.6, 0.1])])
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["in", "out"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "C", typeName: "capacitor", nodes: ["out", "0"], parameters: ["c": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let probe = StartupHistoryProbe(base: devices[2], cancellation: token)
        var wrapped = devices
        wrapped[2] = probe
        return (plan, wrapped, probe, output)
    }

    private func config(output: Node, policy: TransientExecutionLimits) -> TransientConfig {
        .init(stopTime: 0.6, executionLimits: policy, maxTimeStep: 0.2, initialTimeStep: 0.2,
            preferredMethod: .trapezoidal, useInitialConditions: true,
            initialNodeVoltages: [output: 1], gminSteppingThreshold: Int.max)
    }

    @Test func startupAndBreakpointTrialsShareAcceptedHistoryAndCommitOnlyFullSolutions() async throws {
        let (plan, devices, probe, output) = try fixture()
        let buffer = try BufferingObserver(capacity: 10_000)
        let result = try await TransientAnalysis(config: config(output: output, policy: limits()),
            convergenceConfig: .init(reltol: 1e-12, vntol: 0.005, gmin: 0)).run(
                plan: plan, devices: devices, solver: SparseLUSolver(), observer: EventDispatcher(observers: [buffer]),
                cancellation: CancellationToken())
        let observed = probe.snapshot
        #expect(!observed.historyMismatch)
        #expect(observed.ends == 1)
        #expect(observed.commits.count == result.timeSteps)
        #expect(observed.commits[0].method == .backwardEuler)
        #expect(observed.commits[1].method == .backwardEuler)
        #expect(observed.commits[2].method == .backwardEuler)
        let breakpoint = try #require(observed.commits.firstIndex { $0.currentTime == 0.3 })
        #expect(observed.commits[breakpoint + 1].method == .backwardEuler)
        #expect(observed.commits[breakpoint + 2].method == .backwardEuler)
        let events = buffer.events
        let accepted = events.compactMap { event -> TimeStepInfo? in
            if case .timeStepCompleted(let info) = event { return info }; return nil
        }
        #expect(accepted.count == result.timeSteps)
        #expect(try #require(accepted.first).lte > 0)
        #expect(accepted.allSatisfy { $0.lte <= 1 })
        let statistics = try #require(result.executionStatistics)
        #expect(statistics.rejectedSteps > 0)
        #expect(statistics.solveAttempts >= statistics.acceptedSteps + 4)
        // The .3 breakpoint constrains the first full trial to .15, half to .075.
        // RC BE bootstrap defect is approximately .0091, above this fixture's .005.
        let firstHalf = try #require(observed.stamps.first { $0.timeStep == 2 * observed.stamps[0].timeStep })
        #expect(firstHalf.method == .backwardEuler)
        #expect(firstHalf.currentTime == firstHalf.timeStep)
        #expect(observed.stamps.contains {
            $0.currentTime == 2 * firstHalf.currentTime && $0.timeStep == 2 * firstHalf.timeStep
        })
        #expect(!observed.commits.contains {
            $0.currentTime == firstHalf.currentTime && $0.timeStep == firstHalf.timeStep
        })
        #expect(!observed.commits.contains {
            $0.currentTime == 2 * firstHalf.currentTime && $0.timeStep == 2 * firstHalf.timeStep
        })
        let rejections = events.compactMap { event -> TimeStepRejectInfo? in
            if case .timeStepRejected(let info) = event { return info }; return nil
        }
        #expect(try #require(rejections.first).reason.hasPrefix("LTE exceeded tolerance"))
    }

    @Test("Accepted LTE proposals stay at the configured minimum", arguments: [2.0, 1.5])
    func acceptedProposalRespectsMinimumTimeStep(stopTime: Double) async throws {
        try await checkMinimumStepRamp(stopTime: stopTime, waveformEnd: 4)
    }

    @Test("Breakpoint approach does not split below the configured minimum")
    func breakpointApproachRespectsMinimumTimeStep() async throws {
        try await checkMinimumStepRamp(stopTime: 1.5, waveformEnd: 1.5)
    }

    private func checkMinimumStepRamp(stopTime: Double, waveformEnd: Double) async throws {
        var netlist = Netlist()
        _ = netlist.node("in")
        let output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["pwl": .realVector([0, 0, waveformEnd, waveformEnd])])
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["in", "out"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "C", typeName: "capacitor", nodes: ["out", "0"], parameters: ["c": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let observer = try BufferingObserver(capacity: 1_000)
        let config = TransientConfig(stopTime: stopTime, executionLimits: limits(), maxTimeStep: 1,
            initialTimeStep: 1, minTimeStep: 1, preferredMethod: .backwardEuler, useInitialConditions: true,
            gminSteppingThreshold: Int.max)
        do {
            let result = try await TransientAnalysis(config: config,
                convergenceConfig: .init(reltol: 1e-12, vntol: 0.2, gmin: 0)).run(
                    plan: plan, devices: devices, solver: SparseLUSolver(),
                    observer: EventDispatcher(observers: [observer]), cancellation: CancellationToken())
            #expect(result.timePoints == [0, 1, stopTime])
            #expect(result.timeSteps == 2)
            #expect(result.rejectedSteps == 0)
            #expect(abs(try result.voltage(at: output, timeIndex: 1) - 0.5) < 1e-12)
            let finalVoltage = stopTime == 2 ? 1.25 : 5.0 / 6.0
            #expect(abs(try result.voltage(at: output, timeIndex: 2) - finalVoltage) < 1e-12)
        } catch {
            let accepted = observer.events.compactMap { event -> TimeStepInfo? in
                if case .timeStepCompleted(let info) = event { return info }; return nil
            }
            print("ACCEPTED_MINIMUM_PROPOSAL_REFUSAL stop=\(stopTime) waveformEnd=\(waveformEnd) accepted=\(accepted.count) firstTime=\(accepted.first?.time ?? -1) firstStep=\(accepted.first?.timeStep ?? -1) firstLTE=\(accepted.first?.lte ?? -1) error=\(error)")
            throw error
        }
        let accepted = observer.events.compactMap { event -> TimeStepInfo? in
            if case .timeStepCompleted(let info) = event { return info }; return nil
        }
        #expect(accepted.count == 2)
        #expect(abs(try #require(accepted.first).lte - 2.0 / 3.0) < 1e-10)
        #expect(accepted.allSatisfy { $0.lte <= 1 })
    }

    @Test("Newton rejection tries the minimum before failing", arguments: [
        (1.5, 3.0, 1.0), (1.0, 2.0, 0.0), (1.5, 0.75, 0.0)
    ])
    func newtonRejectionTriesMinimumBeforeFailing(initialStep: Double, stopTime: Double,
                                                maximumConvergingStep: Double) async throws {
        var netlist = Netlist()
        _ = netlist.node("in")
        let output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["pwl": .realVector([0, 0, 4, 4])])
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["in", "out"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "C", typeName: "capacitor", nodes: ["out", "0"], parameters: ["c": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let probe = StartupHistoryProbe(base: devices[2], cancellation: nil, maximumConvergingStep: maximumConvergingStep)
        var wrapped = devices
        wrapped[2] = probe
        let observer = try BufferingObserver(capacity: 1_000)
        let config = TransientConfig(stopTime: stopTime, executionLimits: limits(), maxTimeStep: 1.5,
            initialTimeStep: initialStep, minTimeStep: 1, preferredMethod: .backwardEuler,
            useInitialConditions: true, gminSteppingThreshold: Int.max)
        do {
            let result = try await TransientAnalysis(config: config,
                convergenceConfig: .init(reltol: 1e-12, vntol: 0.2, maxIterations: 2, gmin: 0)).run(
                    plan: plan, devices: wrapped, solver: SparseLUSolver(),
                    observer: EventDispatcher(observers: [observer]), cancellation: CancellationToken())
            #expect(maximumConvergingStep == 1)
            // The initial remaining interval permits the oversized trial; endpoint
            // approach splitting must not preempt the deliberate Newton rejection.
            #expect(stopTime - initialStep >= config.minTimeStep)
            #expect(result.timePoints == [0, 1, 2, 3])
            #expect(result.rejectedSteps == 1)
            #expect(abs(try result.voltage(at: output, timeIndex: 1) - 0.5) < 1e-12)
            #expect(abs(try result.voltage(at: output, timeIndex: 2) - 1.25) < 1e-12)
            #expect(abs(try result.voltage(at: output, timeIndex: 3) - 2.125) < 1e-12)
            #expect(probe.snapshot.commits.count == 3)
            let statistics = try #require(result.executionStatistics)
            #expect(statistics.solveAttempts == 12)
            #expect(statistics.newtonIterations == 24)
            #expect(statistics.acceptedSteps == 3 && statistics.rejectedSteps == 1)
        } catch let error as AnalysisError {
            print("NR_MINIMUM_RETRY_REFUSAL initial=\(initialStep) stop=\(stopTime) maximumConverging=\(maximumConvergingStep) commits=\(probe.snapshot.commits.count) error=\(error)")
            #expect(maximumConvergingStep == 0)
            guard case .timestepTooSmall(let step) = error else { Issue.record("Unexpected error: \(error)"); return }
            #expect(step == (stopTime < 1 ? 0.375 : 0.5))
            #expect(probe.snapshot.commits.isEmpty)
        }
        let rejected = observer.events.compactMap { event -> TimeStepRejectInfo? in
            if case .timeStepRejected(let info) = event { return info }; return nil
        }
        #expect(rejected.count == 1)
        #expect(try #require(rejected.first).reason == "Newton-Raphson convergence failure")
        if maximumConvergingStep == 1 {
            #expect(try #require(rejected.first).rejectedStep == initialStep)
            #expect(try #require(rejected.first).newStep == 1)
            #expect(probe.snapshot.stamps.contains { $0.timeStep == 1 && $0.currentTime == 1 })
        }
        #expect(probe.snapshot.ends == 1)
        #expect(!probe.snapshot.historyMismatch)
    }

    @Test func exactCumulativeWorkAndNewtonQuotasReleaseSessions() async throws {
        let (plan, devices, _, output) = try fixture()
        let convergence = ConvergenceConfig(reltol: 1e-12, vntol: 0.005, gmin: 0)
        let baseline = try await TransientAnalysis(config: config(output: output, policy: limits()), convergenceConfig: convergence)
            .run(plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let statistics = try #require(baseline.executionStatistics)
        print("STARTUP_EXACT_QUOTAS work=\(statistics.workUnits) newton=\(statistics.newtonIterations) solves=\(statistics.solveAttempts)")
        for resource in ["workUnits", "newtonIterations"] {
            let exact = resource == "workUnits" ? statistics.workUnits : statistics.newtonIterations
            for deficit in [0, 1] {
                let (plan, devices, probe, output) = try fixture()
                var policy = limits()
                if resource == "workUnits" { policy.maximumWorkUnits = exact - deficit }
                else { policy.maximumNewtonIterations = exact - deficit }
                do {
                    let result = try await TransientAnalysis(config: config(output: output, policy: policy), convergenceConfig: convergence)
                        .run(plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
                    #expect(deficit == 0)
                    let actual = try #require(result.executionStatistics)
                    #expect((resource == "workUnits" ? actual.workUnits : actual.newtonIterations) == exact)
                } catch let error as TransientExecutionError {
                    print("STARTUP_QUOTA_REFUSAL resource=\(resource) exact=\(exact) deficit=\(deficit) error=\(error)")
                    #expect(deficit == 1)
                    guard case .limitExceeded(let actual, let limit, _) = error else { Issue.record("Unexpected error: \(error)"); return }
                    #expect(actual == resource && limit == exact - 1)
                }
                #expect(probe.snapshot.ends == 1)
                #expect(!probe.snapshot.historyMismatch)
            }
        }
    }

    @Test func cancellationDuringHalfTrialCommitsNothingAndReleasesSession() async throws {
        let token = CancellationToken()
        let (plan, devices, probe, output) = try fixture(token: token)
        do {
            _ = try await TransientAnalysis(config: config(output: output, policy: limits()))
                .run(plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: token)
            Issue.record("Cancelled trial returned a complete result")
        } catch let error as AnalysisError {
            guard case .cancelled = error else { Issue.record("Unexpected cancellation: \(error)"); return }
        }
        #expect(probe.snapshot.ends == 1)
        #expect(probe.snapshot.commits.isEmpty)
    }
}

private final class StartupHistoryProbe: TransientSessionDevice {
    struct State: Sendable {
        var accepted: [Double] = []
        var commits: [IntegrationState] = []
        var stamps: [IntegrationState] = []
        var historyMismatch = false
        var ends = 0
        var lastTrialStep = 0.0
    }
    private let state = Mutex(State())
    let base: any BoundDevice
    let cancellation: CancellationToken?
    let maximumConvergingStep: Double?
    init(base: any BoundDevice, cancellation: CancellationToken?, maximumConvergingStep: Double? = nil) {
        self.base = base; self.cancellation = cancellation; self.maximumConvergingStep = maximumConvergingStep
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
        state.withLock {
            $0.historyMismatch = $0.historyMismatch || solution.previousVariables != $0.accepted
            $0.stamps.append(integration)
            $0.lastTrialStep = integration.timeStep
        }
        try base.stampTransient(into: &stamper, state: solution, integration: integration)
        cancellation?.cancel()
    }
    func commitTransientStep(state solution: SolutionState, integration: IntegrationState) throws {
        try (base as? any TransientStateCommittingDevice)?.commitTransientStep(state: solution, integration: integration)
        state.withLock { $0.accepted = solution.variables; $0.commits.append(integration) }
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        if let maximumConvergingStep, self.state.withLock({ $0.lastTrialStep > maximumConvergingStep }) {
            return .notConverged(maxDelta: 1, deviceName: instance.name)
        }
        return base.checkConvergence(state: state, previousState: previousState)
    }
}
