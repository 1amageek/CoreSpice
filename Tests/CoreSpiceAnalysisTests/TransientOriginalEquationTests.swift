import Testing
import Synchronization
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
@testable import CoreSpiceAnalysis

@Suite("Transient original equations", .timeLimit(.minutes(1)))
struct TransientOriginalEquationTests {
    @Test func recoveryFinishesAtZeroGminBeforeHistoryCommit() async throws {
        var netlist = Netlist()
        let output = netlist.node("out")
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"], parameters: ["r": .real(1)])
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["0", "out"], parameters: ["i": .real(1)])
        let plan = try StandardCompiler().compile(ir: netlist.build())
        let circuit = try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances)
        let device = RecoveryHistoryProbe(original: circuit.devices[0], output: output)
        var devices = circuit.devices
        devices[0] = device
        let attempts = RecoveryFactorizationProbe()
        let config = TransientConfig(stopTime: 1, executionLimits: .validationFixture,
            maxTimeStep: 1, initialTimeStep: 1, useInitialConditions: true,
            gminSteppingThreshold: 1, gminStepping: .init(initialGmin: 1, finalGmin: 1, maxSteps: 1))
        let result = try await TransientAnalysis(config: config, physicalResidualValidator: device)
            .run(plan: plan, devices: devices, solver: RecoveryFactorizationSolver(probe: attempts),
                observer: nil, cancellation: CancellationToken())
        #expect(result.timePoints == [0, 1])
        #expect(abs(try result.voltage(at: output, timeIndex: 1) - 1) < 1e-12)
        #expect(device.snapshot == [1, 0])
        let diagonals = attempts.diagonals
        #expect(diagonals.first == 1)
        let regularized = try #require(diagonals.firstIndex(of: 2))
        #expect(diagonals.dropFirst(regularized + 1).contains(1))
        #expect((result.executionStatistics?.solveAttempts ?? 0) > 3)
    }
}

private final class RecoveryFactorizationProbe: Sendable {
    private let state = Mutex<[Double]>([])
    var diagonals: [Double] { state.withLock { $0 } }
    func record(_ diagonal: Double) -> Bool {
        state.withLock { values in
            let first = values.isEmpty
            values.append(diagonal)
            return first
        }
    }
}

private struct RecoveryFactorizationSolver: LinearSolver {
    let probe: RecoveryFactorizationProbe
    private var underlying = SparseLUSolver()
    init(probe: RecoveryFactorizationProbe) { self.probe = probe }
    mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {
        try underlying.configureExecution(control)
    }
    mutating func factorize(matrix: SparseMatrix) throws {
        if probe.record(matrix.values[0]) {
            throw AnalysisError.convergenceFailure(iterations: 1, residualNorm: 1)
        }
        try underlying.factorize(matrix: matrix)
    }
    func solve(rhs: [Double]) throws -> [Double] { try underlying.solve(rhs: rhs) }
    mutating func solve(rhs: [Double], into result: inout [Double]) throws { try underlying.solve(rhs: rhs, into: &result) }
}

private final class RecoveryHistoryProbe: BoundDevice, TransientSessionDevice,
                                          TransientStateCommittingDevice, TransientPhysicalResidualValidating {
    let original: any BoundDevice
    let output: Node
    private let state = Mutex([0, 0])
    var instance: Instance { original.instance }
    var snapshot: [Int] { state.withLock { $0 } }
    init(original: any BoundDevice, output: Node) { self.original = original; self.output = output }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        try original.stampDC(into: &stamper, state: state)
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try original.stampAC(into: &stamper, state: state, omega: omega)
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try original.stampTransient(into: &stamper, state: state, integration: integration)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        original.checkConvergence(state: state, previousState: previousState)
    }
    func beginTransientSession(initialState: SolutionState) throws { state.withLock { $0[1] = 1 } }
    func endTransientSession() { state.withLock { $0[1] = 0 } }
    func validate(state: SolutionState, integration: IntegrationState) throws {
        guard abs(try state.checkedVoltage(at: output) - 1) < 1e-12, snapshot == [0, 1] else {
            throw AnalysisError.invalidConfiguration("Recovery changed accepted history or retained artificial Gmin")
        }
    }
    func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        guard abs(try state.checkedVoltage(at: output) - 1) < 1e-12 else {
            throw AnalysisError.invalidConfiguration("Only the original trial may commit")
        }
        self.state.withLock { $0[0] += 1 }
    }
}
