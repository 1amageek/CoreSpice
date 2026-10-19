import Synchronization
import Testing
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Compensated DC coordinates", .timeLimit(.minutes(1)))
struct CompensatedDCTests {
    @Test func automaticNearShortRetainsSubULPVoltageAndStrictKCL() async throws {
        let fixture = try circuit()
        let probe = Probe()
        var devices = fixture.devices
        devices[1] = Device(base: devices[1], probe: probe)
        let result = try await run(fixture.plan, devices: devices)
        let input = try result.checkedCompensatedVoltage(at: fixture.input)
        let output = try result.checkedCompensatedVoltage(at: fixture.output)
        #expect(input.high == 0.5 && output.high == 0.5)
        #expect(output.low != 0)
        try checkKCL(result, input: fixture.input, output: fixture.output)
        #expect(probe.state.withLock { $0.committedLow != nil })
        try result.withCompensatedSolution { high, low in
            let low = try #require(low)
            #expect(high.count == low.count && high.count == result.variables.count)
            for index in high.indices {
                #expect(try CompensatedValue(high: high[index], low: low[index])
                    == result.checkedCompensatedValue(at: index))
            }
        }
    }

    @Test func fullSourceZeroGminPolishRemovesConfiguredRegularization() async throws {
        let fixture = try circuit()
        let result = try await run(fixture.plan, devices: fixture.devices, gmin: 1e-3)
        try checkKCL(result, input: fixture.input, output: fixture.output)
        #expect(try result.checkedCompensatedVoltage(at: fixture.output).low != 0)
    }

    @Test func sourceRecoveryUsesSameScaleAndCarriesLowCoordinates() async throws {
        let fixture = try circuit()
        let probe = Probe(failures: 2)
        var devices = fixture.devices
        devices[1] = Device(base: devices[1], probe: probe)
        let result = try await run(fixture.plan, devices: devices)
        try checkKCL(result, input: fixture.input, output: fixture.output)
        let calls = probe.state.withLock { $0.calls }
        #expect(calls.contains { $0.scale == 0.5 })
        let outputRow = try #require(result.variableMap[.nodeVoltage(fixture.output)])
        // The next full-source stage starts at the complete preceding half-source state.
        #expect(calls.contains { $0.scale == 1 && $0.high[outputRow] == 0.25 && $0.low[outputRow] != 0 })
    }

    @Test func gminRecoveryPreservesCompleteStateBeforeOriginalPublication() async throws {
        let fixture = try circuit()
        let probe = Probe(failures: 1)
        var devices = fixture.devices
        devices[1] = Device(base: devices[1], probe: probe)
        let result = try await run(fixture.plan, devices: devices)
        try checkKCL(result, input: fixture.input, output: fixture.output)
        #expect(probe.state.withLock { $0.failures == 0 && $0.committedLow != nil })
    }

    @Test func precisionSelectionIsExplicitAndIncompleteCapabilityIsRefused() async throws {
        let fixture = try circuit(resistance: 8, current: 0.03125)
        let ordinary = try await run(fixture.plan, devices: fixture.devices, mode: .binary64)
        #expect(ordinary.variableLowComponents == nil)
        var devices = fixture.devices
        devices[1] = Ordinary(base: devices[1])
        let automatic = try await run(fixture.plan, devices: devices)
        #expect(automatic.variableLowComponents == nil)
        do {
            _ = try await run(fixture.plan, devices: devices, mode: .compensated)
            Issue.record("Requested compensated capability must be complete")
        } catch let error as NumericalStateError {
            #expect(error == .incompatiblePrecisionConfiguration)
        }
    }

    @Test func originalEvaluationFailurePreventsAcceptedStateCommit() async throws {
        let fixture = try circuit()
        let probe = Probe(failing: true)
        var devices = fixture.devices
        devices[1] = Device(base: devices[1], probe: probe)
        do {
            _ = try await run(fixture.plan, devices: devices)
            Issue.record("Original model errors must propagate")
        } catch let error as FixtureFailure {
            #expect(error == .originalEquation)
        }
        #expect(probe.state.withLock { $0.committedLow == nil })
    }

    @Test func resultRejectsMalformedPairsAndPreservesOrdinaryZeroLow() throws {
        let node = Node(id: 1)
        let map: [MNAVariable: Int] = [.nodeVoltage(node): 0]
        #expect(throws: NumericalStateError.lowComponentCountMismatch(expected: 1, actual: 0)) {
            _ = try DCResult(variables: [0.5], variableMap: map, iterations: 1, variableLowComponents: [])
        }
        #expect(throws: NumericalStateError.nonNormalizedPair) {
            _ = try DCResult(variables: [0.5], variableMap: map, iterations: 1, variableLowComponents: [0.5])
        }
        #expect(throws: NumericalStateError.nonFiniteComponent) {
            _ = try DCResult(variables: [0.5], variableMap: map, iterations: 1, variableLowComponents: [.nan])
        }
        let result = try DCResult(variables: [0.5], variableMap: map, iterations: 1)
        #expect(try result.checkedCompensatedVoltage(at: node) == CompensatedValue(high: 0.5))
        #expect(try result.checkedCompensatedVoltage(at: .ground) == .zero)
        #expect(throws: SolutionStateAccessError.valueIndexOutOfBounds(index: -1, count: 1)) {
            _ = try result.checkedCompensatedValue(at: -1)
        }
    }

    private func circuit(resistance: Double = 1e-6, current: Double = 1e-11) throws
        -> (plan: ExecutionPlan, devices: [any BoundDevice], input: Node, output: Node) {
        var netlist = Netlist()
        let input = netlist.node("in")
        let output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"], parameters: ["v": .real(0.5)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"], parameters: ["r": .real(resistance)])
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["out", "0"], parameters: ["i": .real(current)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        return (plan, devices, input, output)
    }

    private func run(_ plan: ExecutionPlan, devices: [any BoundDevice],
                     mode: DCPrecisionMode = .automatic, gmin: Double = 0) async throws -> DCResult {
        try await DCAnalysis(config: .init(abstol: 1e-12, reltol: 0, maxIterations: 20, gmin: gmin),
            gminStepping: .init(initialGmin: 1e-3, finalGmin: 1e-4, maxSteps: 1),
            sourceStepping: .init(steps: 2), precisionMode: mode).run(
                plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil, cancellation: .init())
    }

    private func checkKCL(_ result: DCResult, input: Node, output: Node) throws {
        let voltage = try CompensatedEnclosure(center: result.checkedCompensatedVoltage(at: input))
            .subtracting(CompensatedEnclosure(center: result.checkedCompensatedVoltage(at: output)))
        let current = try voltage.multiplied(by: CompensatedEnclosure(center: CompensatedValue(high: 1e6)))
        let kcl = try current.subtracting(CompensatedEnclosure(center: CompensatedValue(high: 1e-11)))
        #expect(kcl.absoluteUpperBound <= 1e-12)
        #expect(current.absoluteUpperBound > 1e-12)
    }

    private enum FixtureFailure: Error { case originalEquation }

    private final class Probe: Sendable {
        struct Call: Sendable { let scale: Double; let high: [Double]; let low: [Double] }
        struct State: Sendable {
            var failures: Int
            var failing: Bool
            var calls: [Call] = []
            var committedLow: [Double]?
        }
        let state: Mutex<State>
        init(failures: Int = 0, failing: Bool = false) {
            state = Mutex(State(failures: failures, failing: failing))
        }
    }

    private struct Device: BoundDevice, DCPhysicalResidualEnclosureContributing, AcceptedStateCommittingDevice {
        let base: any BoundDevice
        let probe: Probe
        var instance: Instance { base.instance }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws { try base.stampAC(into: &stamper, state: state, omega: omega) }
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws { try base.stampTransient(into: &stamper, state: state, integration: integration) }
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { base.checkConvergence(state: state, previousState: previousState) }
        func accumulatePhysicalResidualEnclosure(state: SolutionState, sourceScale: Double,
            add: (Int, CompensatedValue, Double) -> Void) throws {
            let failure = probe.state.withLock { value -> Bool in
                if value.failing { return true }
                if value.failures > 0 { value.failures -= 1; return true }
                value.calls.append(.init(scale: sourceScale, high: state.variables, low: state.variableLowComponents ?? []))
                return false
            }
            if failure {
                if probe.state.withLock({ $0.failing }) { throw FixtureFailure.originalEquation }
                throw AnalysisError.convergenceFailure(iterations: 1, residualNorm: 1)
            }
            let contributor = try #require(base as? any DCPhysicalResidualEnclosureContributing)
            try contributor.accumulatePhysicalResidualEnclosure(state: state, sourceScale: sourceScale, add: add)
        }
        func commitAcceptedState(_ state: SolutionState) {
            probe.state.withLock { $0.committedLow = state.variableLowComponents }
        }
    }

    private struct Ordinary: BoundDevice {
        let base: any BoundDevice
        var instance: Instance { base.instance }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws { try base.stampAC(into: &stamper, state: state, omega: omega) }
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws { try base.stampTransient(into: &stamper, state: state, integration: integration) }
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { base.checkConvergence(state: state, previousState: previousState) }
    }
}
