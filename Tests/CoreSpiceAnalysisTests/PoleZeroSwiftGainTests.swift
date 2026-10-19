import Testing
import Synchronization
@testable import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

@Suite("Pure Swift pole-zero DC response")
struct PoleZeroSwiftGainTests {
    @Test("Original teraohm divider gain has no artificial conductance")
    func originalGDivider() async throws {
        let circuit = try divider()
        let result = try await PoleZeroAnalysis(outputNode: circuit.output, inputSourceName: "V1")
            .run(plan: circuit.plan, devices: circuit.devices, solver: SparseLUSolver(),
                 observer: nil, cancellation: CancellationToken())
        #expect(abs(result.dcGain - 0.5) <= 8 * Double.ulpOfOne)
    }

    @Test("A corrupted gain solve fails the original-G residual check")
    func corruptGainCannotPublish() async throws {
        let circuit = try divider()
        let index = try #require(circuit.plan.topology.variableMap[.nodeVoltage(circuit.output)])
        let solver = CorruptUnitResponse(outputIndex: index)
        await #expect(throws: (any Error).self) {
            _ = try await PoleZeroAnalysis(outputNode: circuit.output, inputSourceName: "V1")
                .run(plan: circuit.plan, devices: circuit.devices, solver: solver,
                     observer: nil, cancellation: CancellationToken())
        }
    }

    @Test("Actual PZ extraction shares cumulative work and refunds on quota or cancellation")
    func extractionIsControlled() async throws {
        let circuit = try divider()
        let baselineBudget = try budget(plan: circuit.plan, deviceCount: circuit.devices.count, work: 100_000_000)
        let baseline = PoleZeroResourceProbe(budget: baselineBudget)
        try await runControlled(circuit, probe: baseline, token: CancellationToken())
        let observed = baseline.snapshot
        #expect(observed.workAtAC.count == circuit.devices.count)
        #expect(observed.liveBytes == 0)
        #expect(observed.reservations > 0 && observed.peakBytes > 0)
        let firstWork = try #require(observed.workAtAC.first)
        let secondWork = try #require(observed.workAtAC.dropFirst().first)
        #expect(secondWork > firstWork, "Matrix extraction itself must charge work between device stamps")

        let limitedBudget = try budget(plan: circuit.plan, deviceCount: circuit.devices.count, work: firstWork)
        let limited = PoleZeroResourceProbe(budget: limitedBudget)
        do {
            try await runControlled(circuit, probe: limited, token: CancellationToken())
            Issue.record("Expected quota refusal before the second AC device stamp")
        } catch TransientExecutionError.limitExceeded(let resource, _, _) {
            #expect(resource == "workUnits")
        }
        #expect(limited.snapshot.workAtAC.count == 1)
        #expect(limited.snapshot.liveBytes == 0)
        #expect(limitedBudget.statistics.workUnits <= firstWork)

        let token = CancellationToken()
        let cancelledBudget = try budget(plan: circuit.plan, deviceCount: circuit.devices.count, work: 100_000_000)
        let cancelled = PoleZeroResourceProbe(budget: cancelledBudget, cancelAfterFirstAC: token)
        do {
            try await runControlled(circuit, probe: cancelled, token: token)
            Issue.record("Expected cancellation after the first AC device stamp")
        } catch AnalysisError.cancelled {}
        #expect(cancelled.snapshot.workAtAC.count == 1)
        #expect(cancelled.snapshot.liveBytes == 0)
    }

    private func budget(plan: ExecutionPlan, deviceCount: Int, work: Int) throws -> TransientExecutionBudget {
        try TransientExecutionBudget(limits: .init(maximumAcceptedSteps: 100,
            maximumSolveAttempts: 1000, maximumNewtonIterations: 1000, maximumSavedScalars: 1000,
            maximumMatrixDimension: 100, maximumWorkUnits: work, maximumBreakpoints: 100),
            dimension: plan.topology.dimension, nonZeroCount: plan.matrixStructure.nonZeroCount, deviceCount: deviceCount)
    }

    private func runControlled(_ circuit: (plan: ExecutionPlan, devices: [any BoundDevice], output: Node),
        probe: PoleZeroResourceProbe, token: CancellationToken) async throws {
        let devices: [any BoundDevice] = circuit.devices.map { ObservedACDevice(base: $0, probe: probe) }
        var analysis = PoleZeroAnalysis(outputNode: circuit.output, inputSourceName: "V1")
        analysis.executionBudget = probe.budget
        analysis.resultStorage = probe
        _ = try await analysis.run(plan: circuit.plan, devices: devices, solver: SparseLUSolver(),
                                   observer: nil, cancellation: token)
    }

    private func divider() throws -> (plan: ExecutionPlan, devices: [any BoundDevice], output: Node) {
        var netlist = Netlist()
        let output = netlist.node("out")
        let _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1e12)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1e12)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-12)])
        let plan = try StandardCompiler().compile(ir: netlist.build())
        let prepared = try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances)
        return (prepared.plan, prepared.devices, output)
    }
}

/// Baseline source is zero, so only the unit small-signal response is corrupted.
private struct CorruptUnitResponse: LinearSolver {
    private var core = SparseLUSolver()
    let outputIndex: Int
    init(outputIndex: Int) { self.outputIndex = outputIndex }
    mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {
        try core.configureExecution(control)
    }
    mutating func factorize(matrix: SparseMatrix) throws { try core.factorize(matrix: matrix) }
    func solve(rhs: [Double]) throws -> [Double] {
        var result = try core.solve(rhs: rhs)
        if rhs.contains(where: { $0 != 0 }) { result[outputIndex] += 0.25 }
        return result
    }
    mutating func solve(rhs: [Double], into result: inout [Double]) throws {
        let solved = try solve(rhs: rhs)
        for index in result.indices { result[index] = solved[index] }
    }
}

private final class PoleZeroResourceProbe: AnalysisResultStorageAccounting {
    struct State: Sendable {
        var workAtAC: [Int] = []
        var liveBytes = 0
        var peakBytes = 0
        var reservations = 0
    }
    let budget: TransientExecutionBudget
    private let state = Mutex(State())
    private let cancelAfterFirstAC: CancellationToken?
    init(budget: TransientExecutionBudget, cancelAfterFirstAC: CancellationToken? = nil) {
        self.budget = budget; self.cancelAfterFirstAC = cancelAfterFirstAC
    }
    var snapshot: State { state.withLock { $0 } }
    func reserveResultScalars(_ capacity: Int) throws {}
    func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
        let count = try #require(Int(exactly: byteCount))
        state.withLock {
            $0.liveBytes += count; $0.peakBytes = max($0.peakBytes, $0.liveBytes); $0.reservations += 1
        }
        return Lease(probe: self, bytes: count)
    }
    func observedAC() {
        let work = budget.statistics.workUnits
        let first = state.withLock { state in
            state.workAtAC.append(work)
            return state.workAtAC.count == 1
        }
        if first { cancelAfterFirstAC?.cancel() }
    }
    private final class Lease: Sendable {
        let probe: PoleZeroResourceProbe
        let bytes: Int
        init(probe: PoleZeroResourceProbe, bytes: Int) { self.probe = probe; self.bytes = bytes }
        deinit { probe.state.withLock { $0.liveBytes -= bytes } }
    }
}

private struct ObservedACDevice: BoundDevice {
    let base: any BoundDevice
    let probe: PoleZeroResourceProbe
    var instance: Instance { base.instance }
    var poleZeroStampApplicability: PoleZeroStampApplicability { base.poleZeroStampApplicability }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        try base.stampDC(into: &stamper, state: state)
    }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try base.stampAC(into: &stamper, state: state, omega: omega)
        probe.observedAC()
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try base.stampTransient(into: &stamper, state: state, integration: integration)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        base.checkConvergence(state: state, previousState: previousState)
    }
}
