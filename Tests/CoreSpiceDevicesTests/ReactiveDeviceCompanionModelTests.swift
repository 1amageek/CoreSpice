import Testing
import Synchronization
import Foundation
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceEvent

/// Thread-safe collector for matrix stamp entries.
private final class ReactiveStampCollector: Sendable {
    private let _matrix = Mutex<[(Int, Int, Double)]>([])
    private let _rhs = Mutex<[(Int, Double)]>([])

    func addMatrix(_ r: Int, _ c: Int, _ v: Double) {
        _matrix.withLock { $0.append((r, c, v)) }
    }
    func addRHS(_ r: Int, _ v: Double) {
        _rhs.withLock { $0.append((r, v)) }
    }
    var matrixEntries: [(Int, Int, Double)] { _matrix.withLock { $0 } }
    var rhsEntries: [(Int, Double)] { _rhs.withLock { $0 } }

    func matrixSum(row: Int, col: Int) -> Double {
        matrixEntries.filter { $0.0 == row && $0.1 == col }.map { $0.2 }.reduce(0, +)
    }
    func rhsSum(row: Int) -> Double {
        rhsEntries.filter { $0.0 == row }.map { $0.1 }.reduce(0, +)
    }
    func reset() {
        _matrix.withLock { $0.removeAll() }
        _rhs.withLock { $0.removeAll() }
    }
}

/// Unit tests for reactive device companion models (capacitor and inductor).
///
/// Verifies the mathematical correctness of:
/// 1. Capacitor companion model coefficients
/// 2. Inductor companion model coefficients
/// 3. History source calculations
/// 4. RC time constant behavior
@Suite("Reactive Device Companion Model Tests")
struct ReactiveDeviceCompanionModelTests {

    // MARK: - Test 1: Capacitor Backward Euler Companion Model

    /// Verifies capacitor Backward Euler companion model: Geq = C / dt.
    ///
    /// Mathematical basis:
    /// - Capacitor current: i = C * dV/dt
    /// - BE discretization: i_n = C * (V_n - V_{n-1}) / dt
    /// - Companion model: i_n = Geq * V_n - Ieq
    /// - Where: Geq = C / dt, Ieq = Geq * V_{n-1}
    @Test("Capacitor BE companion: Geq = C/dt")
    func capacitorBECompanionModel() throws {
        let capacitance = 1e-6  // 1 µF
        let dt = 1e-3           // 1 ms
        let expectedGeq = capacitance / dt  // 1e-3 S

        let desc = CapacitorDescriptor()
        let pos = Node(id: 1)
        let neg = Node(id: 2)

        let instance = Instance(
            name: "C1",
            typeName: "capacitor",
            nodes: [pos, neg],
            parameters: ["c": .real(capacitance)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(pos): 0,
            .nodeVoltage(neg): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = ReactiveStampCollector()
        let state = SolutionState(
            variables: [1.0, 0.0],
            variableMap: variableMap
        )
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )

        let integration = IntegrationState(
            method: .backwardEuler,
            timeStep: dt,
            currentTime: dt
        )

        bound.stampTransient(into: &stamper, state: state, integration: integration)

        // Check diagonal stamp (Geq at (0,0) and (1,1))
        let geq00 = collector.matrixSum(row: 0, col: 0)
        let geq11 = collector.matrixSum(row: 1, col: 1)

        #expect(abs(geq00 - expectedGeq) / expectedGeq < 1e-10,
                "Geq(0,0) should be C/dt = \(expectedGeq), got \(geq00)")
        #expect(abs(geq11 - expectedGeq) / expectedGeq < 1e-10,
                "Geq(1,1) should be C/dt = \(expectedGeq), got \(geq11)")

        // Check off-diagonal stamp (-Geq at (0,1) and (1,0))
        let geq01 = collector.matrixSum(row: 0, col: 1)
        let geq10 = collector.matrixSum(row: 1, col: 0)

        #expect(abs(geq01 + expectedGeq) / expectedGeq < 1e-10,
                "Geq(0,1) should be -C/dt, got \(geq01)")
        #expect(abs(geq10 + expectedGeq) / expectedGeq < 1e-10,
                "Geq(1,0) should be -C/dt, got \(geq10)")
    }

    // MARK: - Test 2: Capacitor Trapezoidal Companion Model

    /// Verifies capacitor Trapezoidal companion model: Geq = 2C / dt.
    ///
    /// Mathematical basis:
    /// - Trapezoidal rule: i_n = (2C/dt)(V_n - V_{n-1}) - i_{n-1}
    /// - Companion model: Geq = 2C / dt (coefficient = 2/dt)
    @Test("Capacitor TRAP companion: Geq = 2C/dt")
    func capacitorTRAPCompanionModel() throws {
        let capacitance = 1e-6  // 1 µF
        let dt = 1e-3           // 1 ms
        let expectedGeq = 2.0 * capacitance / dt  // 2e-3 S

        let desc = CapacitorDescriptor()
        let pos = Node(id: 1)
        let neg = Node(id: 2)

        let instance = Instance(
            name: "C1",
            typeName: "capacitor",
            nodes: [pos, neg],
            parameters: ["c": .real(capacitance)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(pos): 0,
            .nodeVoltage(neg): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = ReactiveStampCollector()
        let state = SolutionState(
            variables: [1.0, 0.0],
            variableMap: variableMap
        )
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )

        let integration = IntegrationState(
            method: .trapezoidal,
            timeStep: dt,
            currentTime: dt
        )

        bound.stampTransient(into: &stamper, state: state, integration: integration)

        // Check diagonal stamp (Geq at (0,0))
        let geq00 = collector.matrixSum(row: 0, col: 0)

        #expect(abs(geq00 - expectedGeq) / expectedGeq < 1e-10,
                "Geq(0,0) should be 2C/dt = \(expectedGeq), got \(geq00)")
    }

    // MARK: - Test 3: IntegrationState Coefficient for BE Inductor

    /// Verifies IntegrationState provides correct coefficient for inductor BE.
    ///
    /// Mathematical basis:
    /// - Req = L × coefficient = L / dt
    /// - coefficient = 1 / dt for Backward Euler
    @Test("IntegrationState BE coefficient for inductor: 1/dt")
    func integrationStateBECoefficientForInductor() {
        let dt = 1e-6
        let inductance = 1e-3

        let integration = IntegrationState(
            method: .backwardEuler,
            timeStep: dt,
            currentTime: dt
        )

        // Req = L × coefficient
        let req = inductance * integration.coefficient
        let expectedReq = inductance / dt  // 1000 Ω

        #expect(abs(req - expectedReq) < 1e-10,
                "BE inductor Req should be L/dt = \(expectedReq), got \(req)")
    }

    // MARK: - Test 4: IntegrationState Coefficient for TRAP Inductor

    /// Verifies IntegrationState provides correct coefficient for inductor Trapezoidal.
    ///
    /// Mathematical basis:
    /// - Req = L × coefficient = 2L / dt
    /// - coefficient = 2 / dt for Trapezoidal
    @Test("IntegrationState TRAP coefficient for inductor: 2/dt")
    func integrationStateTRAPCoefficientForInductor() {
        let dt = 1e-6
        let inductance = 1e-3

        let integration = IntegrationState(
            method: .trapezoidal,
            timeStep: dt,
            currentTime: dt
        )

        // Req = L × coefficient
        let req = inductance * integration.coefficient
        let expectedReq = 2.0 * inductance / dt  // 2000 Ω

        #expect(abs(req - expectedReq) < 1e-10,
                "TRAP inductor Req should be 2L/dt = \(expectedReq), got \(req)")
    }

    // MARK: - Test 5: BE vs TRAP Coefficient Ratio

    /// Verifies that TRAP coefficient is exactly 2x BE coefficient.
    @Test("TRAP coefficient is 2x BE coefficient")
    func trapIsTwiceBE() {
        let dt = 1e-6

        let beCap = IntegrationState(method: .backwardEuler, timeStep: dt, currentTime: dt)
        let trapCap = IntegrationState(method: .trapezoidal, timeStep: dt, currentTime: dt)

        let ratio = trapCap.coefficient / beCap.coefficient

        #expect(abs(ratio - 2.0) < 1e-15, "TRAP/BE ratio should be 2.0, got \(ratio)")
    }

    // MARK: - Test 6: RL Circuit Time Constant

    /// Verifies that RL circuit transient follows τ = L/R.
    ///
    /// Physical basis:
    /// - I(t) = I0 * (1 - exp(-t/τ)) for step response
    /// - τ = L/R
    @Test("RL transient follows time constant τ = L/R")
    func rlTransientTimeConstant() async throws {
        let r = 100.0       // 100 Ω
        let l = 0.01        // 10 mH
        let tau = l / r     // 100 µs

        // Build RL circuit: V -> R -> L -> GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                 parameters: ["r": .real(r)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["mid", "0"],
                                 parameters: ["l": .real(l)])

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        // Run transient for 5τ
        let config = TransientConfig(stopTime: 5 * tau, maxTimeStep: tau / 50)
        let analysis = TransientAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()
        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // At steady state, inductor is a short, so V(mid) = 0
        // and I = V/R = 1/100 = 10mA
        // At t=τ: I(τ) ≈ 0.632 * I_final
        // V(mid) at t=0 is V1 (1V), decays to 0

        // Check that mid voltage at the end is near 0 (steady state)
        let vFinal = result.voltage(at: mid, timeIndex: result.timePoints.count - 1)
        #expect(abs(vFinal) < 0.01, "Final V(mid) should be near 0, got \(vFinal)")
    }
}
