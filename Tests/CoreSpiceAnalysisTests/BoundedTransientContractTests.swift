import Testing
import Foundation
import CoreSpiceEvent
@testable import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR

@Suite("Bounded Transient Contract", .timeLimit(.minutes(1)))
struct BoundedTransientContractTests {
    @Test func breakpointNeverEnlargesMaximumStep() {
        var manager = BreakpointManager()
        manager.addBreakpoints([1.05e-9])
        #expect(manager.constrainTimeStep(currentTime: 0, proposedStep: 1e-9) <= 1e-9)
    }

    @Test func subFemtosecondBreakpointsArePreserved() {
        var manager = BreakpointManager()
        manager.addBreakpoints([1e-17, 2e-17])
        #expect(manager.constrainTimeStep(currentTime: 0, proposedStep: 1e-16) == 1e-17)
    }

    @Test(arguments: [
        ["v1": ParameterValue.real(1)],
        ["pwl": ParameterValue.string("0 0 1e-9 1")],
        ["v": ParameterValue.string("invalid")],
        ["unsupported_waveform": ParameterValue.real(1)]
    ])
    func malformedSourceNeverBecomesDC(_ parameters: [String: ParameterValue]) throws {
        var netlist = Netlist()
        _ = netlist.node("in")
        _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"], parameters: parameters)
        #expect(throws: DeviceBindingError.self) { try CircuitFactory.compile(netlist) }
    }

    private func limits() -> TransientExecutionLimits {
        TransientExecutionLimits(maximumAcceptedSteps: 100_000, maximumSolveAttempts: 200_000,
            maximumNewtonIterations: 1_000_000, maximumSavedScalars: 1_000_000,
            maximumMatrixDimension: 8, maximumWorkUnits: 100_000_000, maximumBreakpoints: 64)
    }

    private func rc(_ sections: Int, falling: Bool = false) throws -> (Netlist, Node) {
        var netlist = Netlist()
        _ = netlist.node("in")
        _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["pwl": .realVector([0, falling ? 1 : 0, 1e-10, falling ? 0 : 1, 8e-9, falling ? 0 : 1])])
        var out = Node.ground
        for section in 1...sections {
            let name = "n\(section)"
            out = netlist.node(name)
            try netlist.addInstance(name: "R\(section)", typeName: "resistor",
                nodes: [section == 1 ? "in" : "n\(section - 1)", name], parameters: ["r": .real(1_000)])
            try netlist.addInstance(name: "C\(section)", typeName: "capacitor",
                nodes: [name, "0"], parameters: ["c": .real(1e-12)])
        }
        return (netlist, out)
    }

    private func response(_ time: Double, sections: Int) -> Double {
        let duration = 1e-10
        let tau = 1e-9
        func primitive(_ t: Double) -> Double {
            guard t > 0 else { return 0 }
            if sections == 1 { return t + tau * expm1(-t / tau) }
            let slow = (3 - sqrt(5)) / (2 * tau)
            let fast = (3 + sqrt(5)) / (2 * tau)
            return t + (fast / slow * expm1(-slow * t) - slow / fast * expm1(-fast * t)) / (fast - slow)
        }
        return (primitive(time) - primitive(time - duration)) / duration
    }

    private func crossing(_ result: TransientResult, node: Node, threshold: Double, falling: Bool) throws -> Double {
        for index in 1..<result.timePoints.count {
            let previous = try result.voltage(at: node, timeIndex: index - 1)
            let current = try result.voltage(at: node, timeIndex: index)
            if falling ? (previous > threshold && current <= threshold) : (previous < threshold && current >= threshold) {
                return result.timePoints[index - 1] + (threshold - previous) / (current - previous)
                    * (result.timePoints[index] - result.timePoints[index - 1])
            }
        }
        throw AnalysisError.internalError("Expected threshold crossing was absent")
    }

    @Test(arguments: [1, 2], [false, true])
    func publicPWLActualRCAgreesWithAnalyticWaveformAndThresholds(sections: Int, falling: Bool) async throws {
        let (netlist, out) = try rc(sections, falling: falling)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        var initial: [Node: Double] = [:]
        for node in plan.ir.nodes where node != .ground { initial[node] = falling ? 1 : 0 }
        let started = ContinuousClock.now
        var errors: [Double] = []
        for step in [1e-11, 5e-12] {
            let config = TransientConfig(stopTime: 8e-9, executionLimits: limits(), maxTimeStep: step,
                initialTimeStep: step, minTimeStep: 1e-18, useInitialConditions: true,
                initialNodeVoltages: initial, gminSteppingThreshold: Int.max)
            let result = try await TransientAnalysis(config: config,
                convergenceConfig: ConvergenceConfig(reltol: 1e-5, vntol: 1e-9, maxIterations: 20, gmin: 0)).run(
                    plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            #expect(result.timePoints.last == config.stopTime)
            #expect(result.timePoints.contains(1e-10))
            #expect(result.timePoints.count == result.timeSteps + 1)
            for index in 1..<result.timePoints.count {
                #expect(result.timePoints[index] - result.timePoints[index - 1] <= step * (1 + 1e-12))
            }
            var maximumError = 0.0
            for (index, time) in result.timePoints.enumerated() {
                let expected = falling ? 1 - response(time, sections: sections) : response(time, sections: sections)
                maximumError = max(maximumError, abs(try result.voltage(at: out, timeIndex: index) - expected))
            }
            #expect(maximumError < 5e-4)
            for alpha in [0.2, 0.5, 0.8] {
                var lower = 0.0
                var upper = config.stopTime
                for _ in 0..<80 {
                    let midpoint = (lower + upper) / 2
                    if response(midpoint, sections: sections) < alpha { lower = midpoint } else { upper = midpoint }
                }
                let actual = try crossing(result, node: out, threshold: falling ? 1 - alpha : alpha, falling: falling)
                let error = abs(actual - (lower + upper) / 2)
                #expect(error < 1e-12)
                errors.append(error)
            }
            let statistics = try #require(result.executionStatistics)
            #expect(statistics.savedScalars == result.timePoints.count * (plan.topology.dimension + 1))
            #expect(statistics.acceptedSteps == result.timeSteps)
            #expect(statistics.solveAttempts >= statistics.acceptedSteps)
            #expect(statistics.newtonIterations >= statistics.solveAttempts)
            #expect(statistics.workUnits <= (try config.requiredExecutionLimits().maximumWorkUnits))
        }
        for index in 0..<3 { #expect(errors[index + 3] < errors[index]) }
        print("BOUNDED_RC sections=\(sections) falling=\(falling) thresholdErrors=\(errors) elapsed=\(started.duration(to: .now))")
    }

    @Test(arguments: ["acceptedSteps", "solveAttempts", "newtonIterations", "savedScalars", "matrixDimension", "workUnits", "breakpoints"])
    func wholeRunBudgetFailsWithoutCompletedPartialOutput(_ resource: String) async throws {
        let (netlist, _) = try rc(1)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        var policy = limits()
        switch resource {
        case "acceptedSteps": policy.maximumAcceptedSteps = 1
        case "solveAttempts": policy.maximumSolveAttempts = 1
        case "newtonIterations": policy.maximumNewtonIterations = 1
        case "savedScalars": policy.maximumSavedScalars = plan.topology.dimension + 1
        case "matrixDimension": policy.maximumMatrixDimension = 1
        case "workUnits": policy.maximumWorkUnits = 1
        case "breakpoints": policy.maximumBreakpoints = 1
        default: throw AnalysisError.internalError("Unknown test resource")
        }
        let buffered = try BufferingObserver(capacity: 1_000)
        let observer = EventDispatcher(observers: [buffered])
        let analysis = TransientAnalysis(config: TransientConfig(stopTime: 8e-9, executionLimits: policy,
            maxTimeStep: 1e-10, useInitialConditions: true), convergenceConfig: ConvergenceConfig(gmin: 0))
        do {
            _ = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(), observer: observer, cancellation: CancellationToken())
            Issue.record("Budget exhaustion must throw")
        } catch let error as TransientExecutionError {
            guard case .limitExceeded(let actual, _, _) = error else { Issue.record("Unexpected budget error: \(error)"); return }
            #expect(actual == resource)
        } catch let error as WaveformError {
            #expect(resource == "breakpoints")
            guard case .breakpointLimitExceeded = error else { Issue.record("Unexpected waveform error: \(error)"); return }
        }
        let finished = buffered.events.compactMap { event -> AnalysisFinishedInfo? in
            if case .analysisFinished(let info) = event, info.type == .tran { return info }; return nil
        }
        #expect(finished.count == 1)
        #expect(finished.first?.status == .failed)
        #expect(finished.first?.failure != nil)
    }

    @Test func DCRecoveryConsumesSameAttemptBudget() async throws {
        let (netlist, _) = try CircuitFactory.resistiveDivider(v: 1, r1: 1_000, r2: 1_000)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        var policy = limits()
        policy.maximumSolveAttempts = 2
        let analysis = TransientAnalysis(config: TransientConfig(stopTime: 1e-9, executionLimits: policy),
            convergenceConfig: ConvergenceConfig(maxIterations: 1, gmin: 0))
        do {
            _ = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Initial DC recovery must consume the run attempt budget")
        } catch let error as TransientExecutionError {
            #expect(error == .limitExceeded(resource: "solveAttempts", limit: 2, requested: 3))
        }
    }

    @Test func cancellationBeforeAndDuringRunNeverCompletes() async throws {
        let (netlist, _) = try rc(1)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        for before in [true, false] {
            let token = CancellationToken()
            if before { token.cancel() }
            let buffered = try BufferingObserver(capacity: 1_000)
            let analysis = TransientAnalysis(config: TransientConfig(stopTime: 8e-9, executionLimits: limits(),
                maxTimeStep: 1e-10, useInitialConditions: true),
                onStepAccepted: { _, _ in token.cancel() })
            do {
                _ = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(),
                    observer: EventDispatcher(observers: [buffered]), cancellation: token)
                Issue.record("Cancellation must throw")
            } catch let error as AnalysisError { guard case .cancelled = error else { Issue.record("Unexpected error"); return } }
            let finished = buffered.events.compactMap { event -> AnalysisFinishedInfo? in
                if case .analysisFinished(let info) = event, info.type == .tran { return info }; return nil
            }
            #expect(finished.count == 1)
            #expect(finished.first?.status == .cancelled)
        }
    }

    @Test func checkedSizeOverflowAndDecodedInvalidLimitsFailAdmission() throws {
        #expect(throws: TransientExecutionError.self) {
            _ = try TransientExecutionBudget(limits: TransientExecutionLimits(maximumAcceptedSteps: Int.max, maximumSolveAttempts: Int.max, maximumNewtonIterations: Int.max, maximumSavedScalars: Int.max, maximumMatrixDimension: Int.max, maximumWorkUnits: Int.max, maximumBreakpoints: Int.max), dimension: Int.max,
                nonZeroCount: 1, deviceCount: 1)
        }
        var policy = limits()
        policy.maximumSavedScalars = 0
        let decoded = try JSONDecoder().decode(TransientExecutionLimits.self, from: JSONEncoder().encode(policy))
        #expect(throws: TransientExecutionError.self) { try decoded.validate() }
    }

    @Test(arguments: [
        [0.0, 0.0], [0, 0, 0, 1], [0, 0, -1, 1], [0, 0, Double.nan, 1],
        [0, 0, 1, Double.infinity], [0, -Double.greatestFiniteMagnitude, 1, Double.greatestFiniteMagnitude]
    ])
    func invalidTypedPWLIsRejectedBeforeBinding(_ values: [Double]) throws {
        var netlist = Netlist()
        _ = netlist.node("in")
        _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"], parameters: ["pwl": .realVector(values)])
        #expect(throws: DeviceBindingError.self) { try CircuitFactory.compile(netlist) }
    }
    @Test func unrepresentableAdvanceAndNonfiniteLTEFailExplicitly() throws {
        #expect(throws: TransientExecutionError.self) { try TransientAnalysis.validateAdvance(time: 1, step: 1e-300) }
        #expect(throws: TransientExecutionError.self) { try TransientAnalysis.validateAdvance(time: 0, step: .nan) }
        let lte = LTEEstimator().estimate(current: [Double.greatestFiniteMagnitude], previous: [-Double.greatestFiniteMagnitude],
            twoPrevious: [0], timeStep: 1e-300, previousTimeStep: 1e-300, method: .trapezoidal)
        #expect(!lte.isFinite)
    }

    @Test func rejectedMinimumStepCannotLoopOrComplete() async throws {
        let (netlist, _) = try rc(1)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        do {
            _ = try await TransientAnalysis(config: TransientConfig(stopTime: 8e-9, executionLimits: limits(),
                maxTimeStep: 1e-10, initialTimeStep: 1e-10, minTimeStep: 1e-10, lteTolerance: 1e-9,
                useInitialConditions: true), convergenceConfig: ConvergenceConfig(gmin: 0)).run(
                    plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Rejected minimum step must fail")
        } catch let error as AnalysisError {
            guard case .timestepTooSmall = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

    @Test func missingPolicyIsFatalBeforeAnySolve() async throws {
        let (netlist, _) = try rc(1)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        do {
            _ = try await TransientAnalysis(config: TransientConfig(stopTime: 1e-9)).run(
                plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Missing policy must not execute")
        } catch let error as TransientExecutionError { #expect(error == .missingExecutionLimits) }
    }

    @Test func lazyGMINRecoveryIsAdmittedBeforeUnboundedStageAllocation() async throws {
        let (netlist, _) = try rc(1)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        var policy = limits()
        policy.maximumSolveAttempts = 2
        let analysis = TransientAnalysis(config: TransientConfig(stopTime: 8e-9, executionLimits: policy,
            maxTimeStep: 1e-10, useInitialConditions: true, gminSteppingThreshold: 1,
            gminStepping: GminStepping(initialGmin: 1, finalGmin: 0, reductionFactor: 1.nextUp, maxSteps: Int.max)),
            convergenceConfig: ConvergenceConfig(maxIterations: 1, gmin: 0))
        do {
            _ = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Recovery stage creation must remain bounded")
        } catch let error as TransientExecutionError {
            #expect(error == .limitExceeded(resource: "solveAttempts", limit: 2, requested: 3))
        }
    }

    @Test(arguments: [0.0, Double.nan, Double.infinity])
    func invalidDeviceTimeStepCannotReturnCompleted(_ maximum: Double) async throws {
        let (netlist, _) = try rc(1)
        let (plan, devices) = try CircuitFactory.compile(netlist)
        var constrained = devices
        constrained[1] = TimeStepConstraintFixture(base: devices[1], maximumTransientTimeStep: maximum)
        do {
            _ = try await TransientAnalysis(config: TransientConfig(stopTime: 1e-9, executionLimits: limits(),
                useInitialConditions: true)).run(plan: plan, devices: constrained, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Invalid timestep must fail")
        } catch let error as TransientExecutionError {
            guard case .invalidTimeStep = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

}


private struct TimeStepConstraintFixture: TransientTimeStepConstraintDevice {
    let base: any BoundDevice
    let maximumTransientTimeStep: Double
    var instance: Instance { base.instance }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws { try base.stampAC(into: &stamper, state: state, omega: omega) }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws { try base.stampTransient(into: &stamper, state: state, integration: integration) }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { base.checkConvergence(state: state, previousState: previousState) }
}
