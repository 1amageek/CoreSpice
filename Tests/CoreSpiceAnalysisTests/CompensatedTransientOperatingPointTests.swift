import Testing
import Synchronization
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Compensated transient operating-point handoff", .timeLimit(.minutes(1)))
struct CompensatedTransientOperatingPointTests {
    @Test func nonzeroOperatingPointLowComponentsReachSessionHistoryAndFirstStep() async throws {
        var netlist = Netlist()
        let input = netlist.node("in"), output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"], parameters: ["v": .real(0.5)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"], parameters: ["r": .real(1e-6)])
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["out", "0"], parameters: ["i": .real(1e-11)])
        let (plan, original) = try CircuitFactory.compile(netlist)
        let probe = Probe()
        var devices = original
        let resistor = try #require(devices.firstIndex { $0.instance.name == "R1" })
        devices[resistor] = SessionDevice(base: devices[resistor], probe: probe)
        var rows = [DCEquationRowPolicy?](repeating: nil, count: plan.topology.dimension)
        for (variable, index) in plan.topology.variableMap {
            let kind: DCEquationKind
            if case .branchCurrent = variable { kind = .electricalFlow } else { kind = .electricalPotential }
            rows[index] = try .init(kind: kind, variableAbsoluteTolerance: 1e-12, equationAbsoluteTolerance: 1e-12)
        }
        let policy = try DCEquationPolicy(rows: rows.map { try #require($0) })
        let encloser = Encloser(devices: devices, dimension: plan.topology.dimension)
        let analysis = TransientAnalysis(config: .init(stopTime: 1e-9,
            executionLimits: .init(maximumAcceptedSteps: 8, maximumSolveAttempts: 100,
                maximumNewtonIterations: 200, maximumSavedScalars: 1000,
                maximumMatrixDimension: 8, maximumWorkUnits: 10_000_000, maximumBreakpoints: 8),
            maxTimeStep: 1e-9, initialTimeStep: 1e-9, minTimeStep: 1e-15,
            preferredMethod: .backwardEuler, useInitialConditions: false),
            convergenceConfig: .init(abstol: 1e-12, reltol: 1e-6, maxIterations: 20, gmin: 0),
            equationPolicy: policy, physicalResidualEncloser: encloser)
        let result = try await analysis.run(plan: plan, devices: devices, solver: SparseLUSolver(),
            observer: nil, cancellation: CancellationToken())
        let observed = probe.state.withLock { $0 }
        let initial = try #require(observed.initial)
        let trial = try #require(observed.firstTrial)
        let accepted = try #require(observed.firstCommit)
        let initialLow = try #require(initial.variableLowComponents)
        let outputRow = try #require(plan.topology.variableMap[.nodeVoltage(output)])
        #expect(observed.initialization == .operatingPoint)
        #expect(initial.variables[outputRow] == 0.5 && initialLow[outputRow] != 0)
        #expect(trial.variables == initial.variables && trial.variableLowComponents == initialLow)
        #expect(trial.previousVariables == initial.variables && trial.previousVariableLowComponents == initialLow)
        #expect(trial.twoPreviousVariables == initial.variables && trial.twoPreviousVariableLowComponents == initialLow)
        #expect(accepted.previousVariables == initial.variables && accepted.previousVariableLowComponents == initialLow)
        #expect(accepted.twoPreviousVariables == initial.variables && accepted.twoPreviousVariableLowComponents == initialLow)
        #expect(result.timePoints == [0, 1e-9] && result.timeSteps == 1)
        #expect(observed.commits == 1 && observed.ends == 1)
        for index in initial.variables.indices {
            #expect(try result.checkedCompensatedValue(variableIndex: index, timeIndex: 0)
                == initial.checkedCompensatedValue(at: index))
            #expect(try result.checkedCompensatedValue(variableIndex: index, timeIndex: 1)
                == accepted.checkedCompensatedValue(at: index))
        }
        for timeIndex in [0, 1] {
            let inputRow = try #require(plan.topology.variableMap[.nodeVoltage(input)])
            let positive = try CompensatedEnclosure(center: result.checkedCompensatedValue(variableIndex: inputRow, timeIndex: timeIndex))
            let negative = try CompensatedEnclosure(center: result.checkedCompensatedValue(variableIndex: outputRow, timeIndex: timeIndex))
            let current = try positive.subtracting(negative).multiplied(by: .init(center: .init(high: 1e6)))
            let residual = try current.subtracting(.init(center: .init(high: 1e-11)))
            #expect(current.absoluteUpperBound > 1e-12 && residual.absoluteUpperBound <= 1e-12)
        }
    }

    private final class Probe: Sendable {
        struct State: Sendable {
            var initial: SolutionState?
            var initialization: TransientInitialization?
            var firstTrial: SolutionState?
            var firstCommit: SolutionState?
            var commits = 0
            var ends = 0
        }
        let state = Mutex(State())
    }

    private struct SessionDevice: TransientSessionDevice, DCPhysicalResidualEnclosureContributing,
        TransientPhysicalResidualEnclosureContributing {
        let base: any BoundDevice
        let probe: Probe
        var instance: Instance { base.instance }
        func beginTransientSession(initialState: SolutionState) throws {
            try beginTransientSession(initialState: initialState, initialization: .operatingPoint)
        }
        func beginTransientSession(initialState: SolutionState, initialization: TransientInitialization) throws {
            probe.state.withLock { $0.initial = initialState; $0.initialization = initialization }
        }
        func endTransientSession() { probe.state.withLock { $0.ends += 1 } }
        func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
            probe.state.withLock { value in
                if value.firstCommit == nil { value.firstCommit = state }
                value.commits += 1
            }
        }
        func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
        func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws { try base.stampAC(into: &stamper, state: state, omega: omega) }
        func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
            probe.state.withLock { if $0.firstTrial == nil { $0.firstTrial = state } }
            try base.stampTransient(into: &stamper, state: state, integration: integration)
        }
        func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
            base.checkConvergence(state: state, previousState: previousState)
        }
        func accumulatePhysicalResidualEnclosure(state: SolutionState, sourceScale: Double,
            add: (Int, CompensatedValue, Double) -> Void) throws {
            let contributor = try #require(base as? any DCPhysicalResidualEnclosureContributing)
            try contributor.accumulatePhysicalResidualEnclosure(state: state, sourceScale: sourceScale, add: add)
        }
        func accumulateTransientPhysicalResidualEnclosure(state: SolutionState, integration: IntegrationState,
            add: (Int, CompensatedValue, Double) -> Void) throws {
            let contributor = try #require(base as? any TransientPhysicalResidualEnclosureContributing)
            try contributor.accumulateTransientPhysicalResidualEnclosure(state: state, integration: integration, add: add)
        }
    }

    private struct Encloser: TransientPhysicalResidualEnclosing {
        let devices: [any BoundDevice]
        let dimension: Int
        func accumulateResidualEnclosure(state: SolutionState, integration: IntegrationState,
            add: (Int, CompensatedValue, Double) -> Void) throws {
            for device in devices {
                let contributor = try #require(device as? any TransientPhysicalResidualEnclosureContributing)
                try contributor.accumulateTransientPhysicalResidualEnclosure(state: state, integration: integration, add: add)
            }
        }
        func validate(state: SolutionState, integration: IntegrationState) throws {
            var residuals = try [CompensatedEnclosure](repeating: .init(center: .zero), count: dimension)
            var failure: (any Error)?
            try accumulateResidualEnclosure(state: state, integration: integration) { row, center, radius in
                guard failure == nil else { return }
                do {
                    guard residuals.indices.contains(row) else {
                        throw NonlinearPhysicalResidualError.invalidRow(row: row, dimension: dimension)
                    }
                    residuals[row] = try residuals[row].adding(.init(center: center, radius: radius))
                } catch { failure = error }
            }
            if let failure { throw failure }
            for row in residuals.indices where residuals[row].absoluteUpperBound > 1e-12 {
                throw NonlinearPhysicalResidualError.uncertifiedResidual(row: row,
                    upperBound: residuals[row].absoluteUpperBound, tolerance: 1e-12)
            }
        }
    }
}
