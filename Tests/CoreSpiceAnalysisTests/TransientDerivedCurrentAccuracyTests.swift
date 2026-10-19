import Testing
import Synchronization
import CoreSpiceIR
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Derived current time accuracy", .timeLimit(.minutes(1)))
struct TransientDerivedCurrentAccuracyTests {
    @Test(arguments: [IntegrationMethod.backwardEuler, .trapezoidal])
    func timeOnlyChargeHasStrictPhysicalResidualAndSeparatelyConvergingDerivedCurrent(_ method: IntegrationMethod) async throws {
        var errors: [Double] = []
        for step in [0.125, 0.0625, 0.03125] {
            var netlist = Netlist()
            let output = netlist.node("out")
            let sourceBranch = netlist.branch()
            try netlist.addInstance(name: "V", typeName: "vsource", nodes: ["out", "0"],
                parameters: ["pwl": .realVector([0, 0, 1, 1, 2, 2])])
            try netlist.addInstance(name: "Q", typeName: "time_charge", nodes: ["out", "0"])
            let ir = try netlist.build()
            let plan = try StandardCompiler().compile(ir: ir)
            var registry = DeviceRegistry.standard()
            registry.register(TimeChargeDescriptor())
            let prepared = try StandardCircuitDeviceBinding(registry: registry).bind(plan: plan, instances: ir.instances)
            let contributors = try prepared.devices.map { device -> any TransientPhysicalResidualContributing in
                try #require(device as? any TransientPhysicalResidualContributing)
            }
            let validator = TimeChargePhysicalValidator(contributors: contributors, dimension: plan.topology.dimension)
            let rows = try DCEquationPolicy(rows: (0..<plan.topology.dimension).map { index in
                let branch = plan.topology.variableMap[.branchCurrent(sourceBranch)] == index
                return try DCEquationRowPolicy(kind: branch ? .electricalFlow : .electricalPotential,
                    variableAbsoluteTolerance: branch ? 1e-12 : 1e-10,
                    equationAbsoluteTolerance: branch ? 1e-10 : 1e-12)
            })
            let result = try await TransientAnalysis(config: .init(stopTime: 1, executionLimits: .validationFixture,
                maxTimeStep: step, initialTimeStep: step, minTimeStep: step, preferredMethod: method),
                convergenceConfig: .init(reltol: 1e-10, gmin: 0), equationPolicy: rows,
                physicalResidualValidator: validator, errorControlVariables: [.nodeVoltage(output)]).run(
                    plan: plan, devices: prepared.devices, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            let sourceIndex = try #require(plan.topology.variableMap[.branchCurrent(sourceBranch)])
            var maximumError = 0.0
            for (index, time) in result.timePoints.enumerated() {
                #expect(abs(try result.voltage(at: output, timeIndex: index) - time) <= 1e-10)
                let sourceCurrent = try result.value(variableIndex: sourceIndex, timeIndex: index)
                // Source current balances the continuous charge derivative, with the opposite sign.
                maximumError = max(maximumError, abs(sourceCurrent + 2e-6 * time))
            }
            #expect(result.timePoints.last == 1)
            #expect(result.rejectedSteps == 0)
            #expect(validator.snapshot.validations == result.timeSteps)
            #expect(validator.snapshot.maximumResidual <= 1e-12)
            #expect(maximumError > 1e-12)
            #expect(result.acceptedSteps.allSatisfy { $0.timeStep == step })
            if method == .trapezoidal {
                #expect(result.acceptedSteps.dropFirst(2).contains { $0.method == .trapezoidal })
            }
            errors.append(maximumError)
        }
        #expect(errors[0] / errors[1] > 1.9 && errors[0] / errors[1] < 2.1)
        #expect(errors[1] / errors[2] > 1.9 && errors[1] / errors[2] < 2.1)
    }
}

private struct TimeChargeDescriptor: DeviceDescriptor {
    let typeName = "time_charge"
    let portNames = ["positive", "negative"]
    let parameterDescriptors: [ParameterDescriptor] = []
    func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2, instance.nodes[1] == .ground,
              let row = context.nodeIndex(instance.nodes[0]) else { throw TimeChargeFixtureError.invalidBinding }
        return BoundTimeCharge(instance: instance, row: row)
    }
}

/// An explicit time-dependent charge, Q(t)=1e-6*t^2, with dQ/dx=0 for every circuit coordinate.
private final class BoundTimeCharge: TransientSessionDevice, TransientPhysicalResidualContributing {
    struct Accepted: Sendable { let time: Double; let charge: Double; let current: Double }
    private let accepted = Mutex<Accepted?>(nil)
    let instance: Instance
    let row: Int
    init(instance: Instance, row: Int) { self.instance = instance; self.row = row }
    func beginTransientSession(initialState: SolutionState) throws {
        try accepted.withLock {
            guard $0 == nil else { throw TimeChargeFixtureError.activeSession }
            $0 = Accepted(time: 0, charge: 0, current: 0)
        }
    }
    func endTransientSession() { accepted.withLock { $0 = nil } }
    // At a static operating point this time-only charge has no DC current or bias Jacobian.
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {}
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {}
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try stamper.stampRHS(row, -current(integration))
    }
    func accumulateTransientPhysicalResidual(state: SolutionState, integration: IntegrationState,
                                             add: (Int, Double) -> Void) throws {
        let value = try current(integration)
        add(row, value)
    }
    func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        try accepted.withLock { previous in
            guard let old = previous else { throw TimeChargeFixtureError.inactiveSession }
            let value = try Self.current(integration, previous: old)
            previous = Accepted(time: integration.currentTime, charge: 1e-6 * integration.currentTime * integration.currentTime,
                                current: value)
        }
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { .converged }
    private func current(_ integration: IntegrationState) throws -> Double {
        try accepted.withLock { previous in
            guard let previous else { throw TimeChargeFixtureError.inactiveSession }
            return try Self.current(integration, previous: previous)
        }
    }
    private static func current(_ integration: IntegrationState, previous: Accepted) throws -> Double {
        guard integration.timeStep.isFinite, integration.timeStep > 0,
              integration.currentTime > previous.time else { throw TimeChargeFixtureError.invalidIntegration }
        let charge = 1e-6 * integration.currentTime * integration.currentTime
        let value = integration.coefficient * (charge - previous.charge)
            - (integration.method == .trapezoidal ? previous.current : 0)
        guard value.isFinite else { throw TimeChargeFixtureError.invalidIntegration }
        return value
    }
}

private final class TimeChargePhysicalValidator: TransientPhysicalResidualEvaluating {
    struct State: Sendable { var validations = 0; var maximumResidual = 0.0 }
    private let state = Mutex(State())
    let contributors: [any TransientPhysicalResidualContributing]
    let dimension: Int
    init(contributors: [any TransientPhysicalResidualContributing], dimension: Int) {
        self.contributors = contributors; self.dimension = dimension
    }
    var snapshot: State { state.withLock { $0 } }
    func accumulateResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
        for contributor in contributors {
            try contributor.accumulateTransientPhysicalResidual(state: state, integration: integration, add: add)
        }
    }
    func validate(state: SolutionState, integration: IntegrationState) throws {
        var residuals = [Double](repeating: 0, count: dimension)
        var invalid = false
        try accumulateResidual(state: state, integration: integration) { row, value in
            guard residuals.indices.contains(row), value.isFinite else { invalid = true; return }
            residuals[row] += value
        }
        let maximum = residuals.reduce(0) { max($0, abs($1)) }
        guard !invalid, maximum.isFinite, maximum <= 1e-12 else { throw TimeChargeFixtureError.physicalResidual }
        self.state.withLock { $0.validations += 1; $0.maximumResidual = max($0.maximumResidual, maximum) }
    }
}

private enum TimeChargeFixtureError: Error {
    case invalidBinding, activeSession, inactiveSession, invalidIntegration, physicalResidual
}
