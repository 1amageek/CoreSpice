import Testing
import Synchronization
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Dynamic transient contracts", .timeLimit(.minutes(1)))
struct TransientDynamicContractTests {
    private func limits() -> TransientExecutionLimits {
        .init(maximumAcceptedSteps: 20_000, maximumSolveAttempts: 100_000,
              maximumNewtonIterations: 300_000, maximumSavedScalars: 400_000,
              maximumMatrixDimension: 16, maximumWorkUnits: 1_000_000_000, maximumBreakpoints: 32)
    }

    private func fixture() throws -> (ExecutionPlan, [any BoundDevice], Node, Node) {
        var netlist = Netlist()
        _ = netlist.node("in")
        let middle = netlist.node("mid")
        let output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V", typeName: "vsource", nodes: ["in", "0"], parameters: ["v": .real(1)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "out"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "C", typeName: "capacitor", nodes: ["out", "0"], parameters: ["c": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        return (plan, devices, middle, output)
    }

    @Test(arguments: [IntegrationMethod.backwardEuler, .trapezoidal])
    func uicPreservesInitialSampleAndResolvesUnseededAlgebraicNodes(_ method: IntegrationMethod) async throws {
        let (plan, devices, middle, output) = try fixture()
        let result = try await TransientAnalysis(config: .init(stopTime: 2, executionLimits: limits(),
            maxTimeStep: 0.2, initialTimeStep: 0.2, preferredMethod: method,
            useInitialConditions: true, initialNodeVoltages: [output: 0.42]),
            convergenceConfig: .init(gmin: 0)).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(result.operatingPoint == nil)
        #expect(try result.voltage(at: output, timeIndex: 0) == 0.42)
        #expect(try result.voltage(at: middle, timeIndex: 0) == 0)
        #expect(result.timePoints.last == 2)
        #expect(result.acceptedSteps.count == result.timeSteps)
        #expect(result.acceptedSteps.prefix(3).allSatisfy { $0.method == .backwardEuler })
        if method == .trapezoidal {
            #expect(result.acceptedSteps.dropFirst(3).contains { $0.method == .trapezoidal })
        }
        for index in 1..<result.timePoints.count {
            let expected = 1 - 0.58 * exp(-result.timePoints[index] / 2)
            #expect(abs(try result.voltage(at: output, timeIndex: index) - expected) < 0.005)
            let actual = result.acceptedSteps[index - 1]
            #expect(actual.time == result.timePoints[index])
            #expect(abs(actual.timeStep - (result.timePoints[index] - result.timePoints[index - 1])) < 1e-14)
        }
    }

    @Test func initialUICWithoutCommittedHistoryCannotUseEmbeddedPair() async throws {
        let (plan, devices, _, output) = try fixture()
        let step = Double.leastNonzeroMagnitude
        do {
            _ = try await TransientAnalysis(config: .init(stopTime: step, executionLimits: limits(),
                maxTimeStep: step, initialTimeStep: step, minTimeStep: step, useInitialConditions: true,
                initialNodeVoltages: [output: 0.42])).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: CancellationToken())
            Issue.record("Unrepresentable first UIC subdivision must fail")
        } catch let error as TransientExecutionError {
            #expect(error == .invalidTimeStep(0))
        }
    }

    @Test(arguments: [false, true])
    func adjacentEndpointUsesCommittedHistoryAndPreservesNonGroundUIC(_ floating: Bool) async throws {
        var netlist = Netlist()
        let output = netlist.node("out")
        _ = netlist.node("drive")
        let base = floating ? netlist.node("base") : .ground
        _ = netlist.branch()
        let offset = floating ? 2.0 : 0.0
        let baseName = floating ? "base" : "0"
        try netlist.addInstance(name: "V", typeName: "vsource", nodes: ["drive", "0"],
            parameters: ["pwl": .realVector([0, offset + 1, 1, offset + 1, 2, offset + 1])])
        if floating {
            _ = netlist.branch()
            try netlist.addInstance(name: "B", typeName: "vsource", nodes: ["base", "0"], parameters: ["v": .real(offset)])
        }
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["drive", "out"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "C", typeName: "capacitor", nodes: ["out", baseName], parameters: ["c": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let endpoint = 1.0.nextUp
        let result = try await TransientAnalysis(config: .init(stopTime: endpoint, executionLimits: limits(),
            maxTimeStep: 0.125, initialTimeStep: 0.125, useInitialConditions: true,
            initialNodeVoltages: [output: offset + 0.42, base: offset]),
            convergenceConfig: .init(gmin: 0)).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(try result.voltage(at: output, timeIndex: 0) == offset + 0.42)
        #expect(result.timePoints.suffix(2).elementsEqual([1, endpoint]))
        let last = try #require(result.acceptedSteps.last)
        #expect(last.time == endpoint)
        #expect(last.timeStep == endpoint - 1)
        #expect(last.method == .backwardEuler)
        let expected = offset + 1 - 0.58 * exp(-endpoint)
        #expect(abs(try result.voltage(at: output, timeIndex: result.timeSteps) - expected) < 0.005)
    }

    @Test(arguments: [true, false])
    func thermalRowsExcludeElectricalGminInInitialAndTransientSolves(_ uic: Bool) async throws {
        var netlist = Netlist()
        let output = netlist.node("thermal")
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["thermal", "0"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "I", typeName: "isource", nodes: ["0", "thermal"], parameters: ["i": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let policy = try DCEquationPolicy(rows: [.init(kind: .thermalPotential,
            variableAbsoluteTolerance: 1e-4, equationAbsoluteTolerance: 1e-10)])
        let result = try await TransientAnalysis(config: .init(stopTime: 0.2, executionLimits: limits(),
            maxTimeStep: 0.05, useInitialConditions: uic), convergenceConfig: .init(gmin: 1),
            equationPolicy: policy).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(abs(try result.voltage(at: output, timeIndex: result.timeSteps) - 1) < 1e-12)
        #expect((result.operatingPoint == nil) == uic)
    }

    @Test func candidateBoundRejectsWithoutCommitAndFinalizesAfterSessionEnd() async throws {
        let (plan, original, _, output) = try fixture()
        let probe = DynamicTransientProbe(base: original[3], maximum: 0.05)
        var devices = original
        devices[3] = probe
        let result = try await TransientAnalysis(config: .init(stopTime: 0.2, executionLimits: limits(),
            maxTimeStep: 0.2, initialTimeStep: 0.2, useInitialConditions: true,
            initialNodeVoltages: [output: 0.42]), convergenceConfig: .init(vntol: 0.5, gmin: 0),
            physicalResidualValidator: probe, completionFinalizer: probe).run(plan: plan, devices: devices,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        #expect(result.rejectedSteps == 1)
        #expect(result.acceptedSteps.allSatisfy { $0.timeStep <= 0.05 })
        let snapshot = probe.snapshot
        #expect(snapshot.commits == result.timeSteps)
        #expect(snapshot.ends == 1 && snapshot.finalized)
        #expect(snapshot.initialization == .initialConditions)
        #expect(snapshot.validations == result.timeSteps)
    }

    @Test func validatorFailureDoesNotCommitOrComplete() async throws {
        let (plan, original, _, output) = try fixture()
        let probe = DynamicTransientProbe(base: original[3], maximum: nil, failsValidation: true)
        var devices = original
        devices[3] = probe
        let events = try BufferingObserver(capacity: 1_000)
        do {
            _ = try await TransientAnalysis(config: .init(stopTime: 0.1, executionLimits: limits(),
                useInitialConditions: true, initialNodeVoltages: [output: 0.42]),
                convergenceConfig: .init(vntol: 0.5, gmin: 0), physicalResidualValidator: probe,
                completionFinalizer: probe).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                    observer: EventDispatcher(observers: [events]), cancellation: CancellationToken())
            Issue.record("Physical validation must fail")
        } catch let error as DynamicTransientFailure { #expect(error == .validation) }
        #expect(probe.snapshot.commits == 0)
        #expect(probe.snapshot.ends == 1)
        #expect(!probe.snapshot.finalized)
        #expect(!events.events.contains { if case .analysisFinished(let info) = $0 { return info.status == .completed }; return false })
    }

    @Test func extractedOperatingPointRetainsInvocationCapacityAfterParentRelease() async throws {
        final class CapacityLease: Sendable {}
        let (plan, devices, _, output) = try fixture()
        let numerical = try await TransientAnalysis(config: .init(stopTime: 0.1, executionLimits: limits()),
            convergenceConfig: .init(gmin: 0)).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        weak var observedLease: CapacityLease?
        var parent: TransientResult?
        do {
            let lease = CapacityLease()
            observedLease = lease
            parent = numerical.retainingStorage(lease)
        }
        var extracted = parent?.operatingPoint
        parent = nil
        #expect(abs(try #require(extracted).voltage(at: output) - 1) < 1e-12)
        withExtendedLifetime(extracted) { #expect(observedLease != nil) }
        extracted = nil
        #expect(observedLease == nil)
    }

    @Test func operatingPointEvidenceIsActualAndInitializationIsExplicit() async throws {
        let (plan, original, _, _) = try fixture()
        let probe = DynamicTransientProbe(base: original[3], maximum: nil)
        var devices = original
        devices[3] = probe
        let result = try await TransientAnalysis(config: .init(stopTime: 0.1, executionLimits: limits()),
            convergenceConfig: .init(gmin: 0)).run(plan: plan, devices: devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        let operatingPoint = try #require(result.operatingPoint)
        try result.withSolution(at: 0) { #expect(Array($0) == operatingPoint.variables) }
        #expect(probe.snapshot.initialization == .operatingPoint)
    }
}

private enum DynamicTransientFailure: Error { case validation, order }

private final class DynamicTransientProbe: TransientSessionDevice, TransientTrialTimeStepConstraintDevice, TransientTimeStepConstraintDevice,
    TransientPhysicalResidualValidating, AnalysisCompletionFinalizing {
    struct State: Sendable {
        var commits = 0
        var ends = 0
        var validations = 0
        var finalized = false
        var initialization: TransientInitialization?
    }
    private let state = Mutex(State())
    let base: any BoundDevice
    let maximum: Double?
    let failsValidation: Bool
    init(base: any BoundDevice, maximum: Double?, failsValidation: Bool = false) {
        self.base = base; self.maximum = maximum; self.failsValidation = failsValidation
    }
    var snapshot: State { state.withLock { $0 } }
    var maximumTransientTimeStep: Double {
        state.withLock { $0.commits == 0 ? .infinity : (maximum ?? .infinity) }
    }
    var instance: Instance { base.instance }
    func beginTransientSession(initialState: SolutionState) throws {
        try (base as? any TransientSessionDevice)?.beginTransientSession(initialState: initialState)
    }
    func beginTransientSession(initialState: SolutionState, initialization: TransientInitialization) throws {
        try beginTransientSession(initialState: initialState)
        state.withLock { $0.initialization = initialization }
    }
    func endTransientSession() {
        (base as? any TransientSessionDevice)?.endTransientSession()
        state.withLock { $0.ends += 1 }
    }
    func maximumTransientTimeStep(state: SolutionState, integration: IntegrationState) throws -> Double? { maximum }
    func validate(state: SolutionState, integration: IntegrationState) throws {
        if failsValidation { throw DynamicTransientFailure.validation }
        self.state.withLock { $0.validations += 1 }
    }
    func finalizeCompletion() throws {
        try state.withLock {
            guard $0.ends == 1 else { throw DynamicTransientFailure.order }
            $0.finalized = true
        }
    }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try base.stampAC(into: &stamper, state: state, omega: omega)
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try base.stampTransient(into: &stamper, state: state, integration: integration)
    }
    func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        try (base as? any TransientStateCommittingDevice)?.commitTransientStep(state: state, integration: integration)
        self.state.withLock { $0.commits += 1 }
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        base.checkConvergence(state: state, previousState: previousState)
    }
}
