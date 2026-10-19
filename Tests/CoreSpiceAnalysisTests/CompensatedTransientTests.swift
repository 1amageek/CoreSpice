import Testing
import Synchronization
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Compensated transient histories", .timeLimit(.minutes(1)))
struct CompensatedTransientTests {
    @Test(arguments: [IntegrationMethod.backwardEuler, .trapezoidal])
    func nonlinearThermalFixturePassesOnePicoWattAndRetainsRetryHistory(_ method: IntegrationMethod) async throws {
        let (plan, model, node) = try fixture(rejectCandidate: true)
        let result = try await analysis(node: node, method: method, model: model).run(
            plan: plan, devices: [model], solver: SparseLUSolver(), observer: nil, cancellation: .init())
        #expect(result.timePoints.last == 4 * ThermalPrecisionFixture.h)
        #expect(result.rejectedSteps >= 1)
        let low = try #require(result.solutionLowTrace)
        #expect(low.rowMajorValues.contains { $0 != 0 })
        #expect(model.snapshot.ends == 1 && model.snapshot.commits == result.timeSteps)
        #expect(!model.snapshot.historyMismatch)
        var previousOffset = 0.0
        var previousIq = 0.0
        for index in result.acceptedSteps.indices {
            let step = result.acceptedSteps[index]
            let value = try result.checkedCompensatedValue(variableIndex: 0, timeIndex: index + 1)
            // Independent binary64 arithmetic on the small offset has ample precision;
            // it never subtracts rounded absolute temperatures or calls the model helper.
            let offset = (value.high - 0.5) + value.low
            let h = step.timeStep + step.timeStepLowComponent
            let iq = (step.method == .backwardEuler ? 1 : 2) * 0x1p-37 * (offset - previousOffset) / h
                - (step.method == .trapezoidal ? previousIq : 0)
            let target = 0.25 * step.time
            let source = 0x1p-39 + 0x1p77 * target * target
            let original = 0x1p77 * offset * offset - source + iq
            #expect(abs(original) <= 1e-12)
            #expect(abs(offset - target) < 1e-18)
            previousOffset = offset; previousIq = iq
            let exactInterval = try CompensatedValue(high: step.time).subtracting(
                CompensatedValue(high: result.timePoints[index]))
            #expect(try exactInterval == CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent))
        }
        #expect(result.acceptedSteps.prefix(3).allSatisfy { $0.method == .backwardEuler })
        if method == .trapezoidal { #expect(result.acceptedSteps.contains { $0.method == .trapezoidal }) }
        let expectedScalars = result.timePoints.count * 3
            + result.timeSteps * ((MemoryLayout<TransientAcceptedStep>.stride + 7) / 8)
        #expect(result.executionStatistics?.savedScalars == expectedScalars)
        try result.withCompensatedSolution(at: 1) { high, low in
            #expect(high[0] == 0.5 && low?[0] != 0)
        }
    }

    @Test func roundedAbsoluteTemperatureCannotSatisfyTheSameFirstStepEquation() {
        let exactIncrement = 0x1p-56
        let source = 0x1p-39 + 0x1p-35
        #expect(0.5 + exactIncrement == 0.5)
        #expect(abs(-source) > 1e-12)
        #expect(0x1p77 * exactIncrement * exactIncrement + 0x1p-37 * exactIncrement / ThermalPrecisionFixture.h == source)
        // An unbounded first-order F(high)+G(high)*low drops the quadratic 2^-35 term.
        #expect(0x1p-35 > 1e-12)
    }

    @Test func lowTraceAndExactIntervalRoundTripWithoutReconstruction() throws {
        var high = try SolutionTrace(variableCount: 1, rowMajorValues: [0.5, 0.5, 0.5])
        let low = try SolutionTrace(variableCount: 1, rowMajorValues: [0, 0x1p-56, 0x1p-55])
        let interval = try CompensatedValue(high: 1).subtracting(CompensatedValue(high: 0x1p-54))
        let records = [TransientAcceptedStep(time: 0x1p-54, timeStep: 0x1p-54, method: .backwardEuler, previousTimeStep: nil),
            TransientAcceptedStep(time: 1, timeStep: interval.high, method: .trapezoidal, previousTimeStep: 0x1p-54,
                timeStepLowComponent: interval.low, previousTimeStepLowComponent: 0)]
        let result = try TransientResult(timePoints: [0, 0x1p-54, 1], solutionTrace: high,
            variableMap: [.nodeVoltage(Node(id: 1)): 0], timeSteps: 2, rejectedSteps: 0,
            acceptedSteps: records, solutionLowTrace: low)
        let restored = try TransientResult(timePoints: result.timePoints,
            solutionTrace: SolutionTrace(variableCount: 1, rowMajorValues: result.solutionTrace.rowMajorValues),
            variableMap: result.variableMap, timeSteps: result.timeSteps, rejectedSteps: result.rejectedSteps,
            acceptedSteps: result.acceptedSteps,
            solutionLowTrace: SolutionTrace(variableCount: 1, rowMajorValues: low.rowMajorValues))
        #expect(try restored.checkedCompensatedValue(variableIndex: 0, timeIndex: 2).low.bitPattern == Double(0x1p-55).bitPattern)
        #expect(restored.acceptedSteps[1].timeStepLowComponent.bitPattern == (-Double(0x1p-54)).bitPattern)
        high = try SolutionTrace(variableCount: 1, rowMajorValues: [0.5])
        #expect(throws: AnalysisResultValidationError.countMismatch(field: "solutionLowTrace", expected: 1, actual: 3)) {
            try TransientResult(timePoints: [0], solutionTrace: high, variableMap: [:], timeSteps: 0,
                rejectedSteps: 0, solutionLowTrace: low)
        }
    }

    @Test func pairedTwoPointResultRequiresItsExactStepAudit() throws {
        let high = try SolutionTrace(variableCount: 1, rowMajorValues: [0.5, 0.5])
        let low = try SolutionTrace(variableCount: 1, rowMajorValues: [0, 0x1p-56])
        let variables: [MNAVariable: Int] = [.nodeVoltage(Node(id: 1)): 0]
        #expect(throws: AnalysisResultValidationError.countMismatch(field: "acceptedSteps", expected: 1, actual: 0)) {
            try TransientResult(timePoints: [0, 1], solutionTrace: high, variableMap: variables,
                timeSteps: 1, rejectedSteps: 0, solutionLowTrace: low)
        }
        let ordinary = try TransientResult(timePoints: [0, 1], solutionTrace: high,
            variableMap: variables, timeSteps: 1, rejectedSteps: 0)
        #expect(ordinary.acceptedSteps.isEmpty && ordinary.solutionLowTrace == nil)
    }

    @Test func pairedInitialPointAllowsAnEmptyZeroStepAudit() throws {
        let result = try TransientResult(timePoints: [0],
            solutionTrace: SolutionTrace(variableCount: 1, rowMajorValues: [0.5]),
            variableMap: [.nodeVoltage(Node(id: 1)): 0], timeSteps: 0, rejectedSteps: 0,
            solutionLowTrace: SolutionTrace(variableCount: 1, rowMajorValues: [0]))
        #expect(result.acceptedSteps.isEmpty)
        #expect(try result.checkedCompensatedValue(variableIndex: 0, timeIndex: 0) == CompensatedValue(high: 0.5))
    }

    @Test func precisionOutputCannotBypassSavedScalarQuota() async throws {
        let (plan, model, node) = try fixture(rejectCandidate: false)
        do {
            _ = try await analysis(node: node, method: .backwardEuler, model: model, savedLimit: 3).run(
                plan: plan, devices: [model], solver: SparseLUSolver(), observer: nil, cancellation: .init())
            Issue.record("A paired accepted point requires both component scalars")
        } catch let error as TransientExecutionError {
            guard case .limitExceeded(let resource, _, _) = error else { throw error }
            #expect(resource == "savedScalars")
        }
        #expect(model.snapshot.commits == 0 && model.snapshot.ends == 1)
    }

    private func fixture(rejectCandidate: Bool) throws -> (ExecutionPlan, ThermalPrecisionFixture, Node) {
        var netlist = Netlist()
        let node = netlist.node("t")
        try netlist.addInstance(name: "R", typeName: "resistor", nodes: ["t", "0"], parameters: ["r": .real(1)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        return (plan, ThermalPrecisionFixture(instance: devices[0].instance, rejectCandidate: rejectCandidate), node)
    }

    private func analysis(node: Node, method: IntegrationMethod, model: ThermalPrecisionFixture,
                          savedLimit: Int = 1_000) throws -> TransientAnalysis {
        let config = TransientConfig(stopTime: 4 * ThermalPrecisionFixture.h,
            executionLimits: .init(maximumAcceptedSteps: 32, maximumSolveAttempts: 200,
                maximumNewtonIterations: 1_000, maximumSavedScalars: savedLimit, maximumMatrixDimension: 4,
                maximumWorkUnits: 10_000_000, maximumBreakpoints: 8),
            maxTimeStep: ThermalPrecisionFixture.h, initialTimeStep: ThermalPrecisionFixture.h,
            minTimeStep: ThermalPrecisionFixture.h / 16, preferredMethod: method,
            useInitialConditions: true, initialNodeVoltages: [node: 0.5], gminSteppingThreshold: .max)
        return try TransientAnalysis(config: config, convergenceConfig: .init(reltol: 0x1p-52, maxIterations: 30, gmin: 0),
            equationPolicy: DCEquationPolicy(rows: [.init(kind: .thermalPotential,
                variableAbsoluteTolerance: 1e-9, equationAbsoluteTolerance: 1e-12)]), physicalResidualEncloser: model)
    }
}

private final class ThermalPrecisionFixture: TransientPhysicalResidualEnclosing,
    TransientPhysicalResidualEnclosureContributing, TransientSessionDevice, TransientTrialTimeStepConstraintDevice {
    static let h: Double = 0x1p-54
    let instance: Instance
    let rejectCandidate: Bool
    struct History: Sendable {
        var accepted = CompensatedValue.zero
        var acceptedIq: CompensatedEnclosure?
        var time = 0.0
        var commits = 0
        var ends = 0
        var historyMismatch = false
    }
    private let history = Mutex(History())
    var snapshot: History { history.withLock { $0 } }
    init(instance: Instance, rejectCandidate: Bool) { self.instance = instance; self.rejectCandidate = rejectCandidate }

    func beginTransientSession(initialState: SolutionState) throws {
        let initial = try initialState.checkedCompensatedValue(at: 0)
        history.withLock { $0 = History(accepted: initial) }
    }
    func endTransientSession() { history.withLock { $0.ends += 1 } }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { stamper.stampMatrix(0, 0, 1) }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {}
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        let value = try state.checkedCompensatedValue(at: 0)
        let offset = (value.high - 0.5) + value.low
        let h = integration.timeStep + integration.timeStepLowComponent
        stamper.stampMatrix(0, 0, 2 * 0x1p77 * offset + (integration.method == .backwardEuler ? 1 : 2) * 0x1p-37 / h)
    }
    func maximumTransientTimeStep(state: SolutionState, integration: IntegrationState) throws -> Double? {
        rejectCandidate && snapshot.time == Self.h && integration.timeStep > Self.h / 2 ? Self.h / 2 : nil
    }

    private func equations(state: SolutionState, integration: IntegrationState) throws -> (CompensatedEnclosure, CompensatedEnclosure) {
        let prior = snapshot
        let value = try state.checkedCompensatedValue(at: 0)
        let previous = try CompensatedValue(high: state.previousVariables![0], low: state.previousVariableLowComponents?[0] ?? 0)
        if previous != prior.accepted { history.withLock { $0.historyMismatch = true } }
        let x = try CompensatedEnclosure(center: value)
        let offset = try x.subtracting(CompensatedEnclosure(center: CompensatedValue(high: 0.5)))
        let delta = try x.subtracting(CompensatedEnclosure(center: prior.accepted))
        var iq = try delta.multiplied(by: scalar(0x1p-37)).divided(by: CompensatedEnclosure(center: integration.compensatedTimeStep))
        if integration.method == .trapezoidal {
            iq = try iq.multiplied(by: scalar(2)).subtracting(prior.acceptedIq!)
        }
        let target = integration.currentTime * 0.25
        let power = 0x1p-39 + 0x1p77 * target * target
        let physical = try offset.multiplied(by: offset).multiplied(by: scalar(0x1p77))
            .subtracting(scalar(power)).adding(iq)
        return (physical, iq)
    }
    private func scalar(_ x: Double) throws -> CompensatedEnclosure { try .init(center: CompensatedValue(high: x)) }
    func accumulateResidualEnclosure(state: SolutionState, integration: IntegrationState,
                                    add: (Int, CompensatedValue, Double) -> Void) throws {
        let equation = try equations(state: state, integration: integration).0
        add(0, equation.center, equation.radius)
    }
    func accumulateTransientPhysicalResidualEnclosure(state: SolutionState, integration: IntegrationState,
                                                      add: (Int, CompensatedValue, Double) -> Void) throws {
        try accumulateResidualEnclosure(state: state, integration: integration, add: add)
    }
    func validate(state: SolutionState, integration: IntegrationState) throws {
        let residual = try equations(state: state, integration: integration).0
        guard residual.absoluteUpperBound <= 1e-12 else {
            throw NonlinearPhysicalResidualError.uncertifiedResidual(row: 0, upperBound: residual.absoluteUpperBound, tolerance: 1e-12)
        }
    }
    func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        let iq = try equations(state: state, integration: integration).1
        let value = try state.checkedCompensatedValue(at: 0)
        history.withLock { $0.accepted = value; $0.acceptedIq = iq; $0.time = integration.currentTime; $0.commits += 1 }
    }
}
