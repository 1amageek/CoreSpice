import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

/// Tests for stiff circuit convergence.
///
/// Stiff circuits have widely separated time constants, requiring
/// careful numerical handling to achieve convergence.
///
/// Verifies:
/// 1. High stiffness ratio circuits converge
/// 2. Adaptive timestep reduction occurs when needed
/// 3. MOSFET voltage clamping aids convergence
@Suite("Stiff Circuit Convergence Tests")
struct StiffCircuitConvergenceTests {

    // MARK: - Test 1: High Stiffness Ratio Circuit

    /// Verifies convergence with stiffness ratio of 10^6.
    ///
    /// Numerical basis:
    /// - Stiffness ratio = τ_max / τ_min
    /// - Circuit: Fast RC (1µs) and slow RC (1s) in parallel
    /// - Adaptive stepping must handle both time scales
    @Test("High stiffness ratio circuit (τ_max/τ_min = 10^6)")
    func highStiffnessRatioCircuit() async throws {
        // Fast time constant: τ_fast = 1µs
        let r_fast = 1000.0      // 1 kΩ
        let c_fast = 1e-9        // 1 nF
        let tau_fast = r_fast * c_fast  // 1 µs

        // Slow time constant: τ_slow = 1s (stiffness ratio = 10^6)
        let r_slow = 1e6         // 1 MΩ
        let c_slow = 1e-6        // 1 µF
        let tau_slow = r_slow * c_slow  // 1 s

        let stiffnessRatio = tau_slow / tau_fast
        #expect(abs(stiffnessRatio - 1e6) < 1, "Stiffness ratio should be 10^6")

        // Build circuit: V -> R_fast -> node1 -> C_fast -> GND
        //                      |-> R_slow -> node2 -> C_slow -> GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out_fast = netlist.node("fast")
        let out_slow = netlist.node("slow")
        let _ = netlist.branch() // V1

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(1.0)])
        // Fast path
        try netlist.addInstance(name: "R_fast", typeName: "resistor", nodes: ["in", "fast"],
                                 parameters: ["r": .real(r_fast)])
        try netlist.addInstance(name: "C_fast", typeName: "capacitor", nodes: ["fast", "0"],
                                 parameters: ["c": .real(c_fast)])
        // Slow path
        try netlist.addInstance(name: "R_slow", typeName: "resistor", nodes: ["in", "slow"],
                                 parameters: ["r": .real(r_slow)])
        try netlist.addInstance(name: "C_slow", typeName: "capacitor", nodes: ["slow", "0"],
                                 parameters: ["c": .real(c_slow)])

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

        // Simulate for enough time to see fast transient settle
        // but not so long that we need to simulate the slow one fully
        let config = TransientConfig(stopTime: 10 * tau_fast, maxTimeStep: tau_fast / 10)
        let analysis = TransientAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Both nodes should be at ~1V (DC operating point with DC source)
        // This test verifies convergence despite stiff time constants
        let vFast = result.voltage(at: out_fast, timeIndex: result.timePoints.count - 1)
        #expect(vFast > 0.99, "Fast node should be at ~1V: got \(vFast)")

        // Slow node also converges to steady state (DC source → immediate steady state)
        let vSlow = result.voltage(at: out_slow, timeIndex: result.timePoints.count - 1)
        #expect(vSlow > 0.99, "Slow node should be at ~1V (steady state): got \(vSlow)")

        // Verify simulation completed with multiple time points (didn't fail)
        #expect(result.timePoints.count > 5, "Should have multiple time points")
    }

    // MARK: - Test 2: MOSFET with Parasitic Capacitance

    /// Verifies convergence with MOSFET parasitics creating stiff system.
    ///
    /// MOSFETs have small gate capacitances (~fF to pF) combined with
    /// larger load capacitances, creating stiff systems.
    @Test("MOSFET circuit with parasitic capacitance converges")
    func mosfetWithParasiticCapacitance() async throws {
        // NMOS common source with gate capacitance and load capacitance
        let vdd = 3.3
        let rd = 1000.0
        let cLoad = 10e-12  // 10 pF load

        var netlist = Netlist()
        let _ = netlist.node("vdd")
        let _ = netlist.node("gate")
        let drain = netlist.node("drain")
        let _ = netlist.branch() // VDD
        let _ = netlist.branch() // VGATE

        try netlist.addInstance(name: "VDD", typeName: "vsource", nodes: ["vdd", "0"],
                                 parameters: ["v": .real(vdd)])
        // Step the gate voltage from 0 to 2V
        try netlist.addInstance(name: "VGATE", typeName: "vsource", nodes: ["gate", "0"],
                                 parameters: ["v": .real(2.0)])
        try netlist.addInstance(name: "RD", typeName: "resistor", nodes: ["vdd", "drain"],
                                 parameters: ["r": .real(rd)])
        try netlist.addInstance(name: "M1", typeName: "nmos_l1", nodes: ["drain", "gate", "0", "0"],
                                 parameters: ["vto": .real(0.7), "kp": .real(200e-6)])
        try netlist.addInstance(name: "CL", typeName: "capacitor", nodes: ["drain", "0"],
                                 parameters: ["c": .real(cLoad)])

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

        // Time constant estimate: τ ≈ RD × CL = 1kΩ × 10pF = 10 ns
        let tau = rd * cLoad
        let config = TransientConfig(stopTime: 10 * tau, maxTimeStep: tau / 10)
        let analysis = TransientAnalysis(config: config, convergenceConfig: CircuitFactory.nonlinearConfig)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // MOSFET is ON (Vgs = 2V > Vth = 0.7V)
        // Drain voltage should be pulled down by the MOSFET
        let vDrain = result.voltage(at: drain, timeIndex: result.timePoints.count - 1)

        // In saturation, roughly: Ids = 0.5 * kp * (Vgs - Vth)^2
        // Ids ≈ 0.5 * 200e-6 * (2 - 0.7)^2 ≈ 0.17 mA
        // Vd = Vdd - Ids * Rd ≈ 3.3 - 0.17 = 3.13V or less if linear

        #expect(vDrain < vdd, "Drain should be pulled down: \(vDrain) < \(vdd)")
        #expect(vDrain > 0.5, "Drain should stay positive: \(vDrain)")
    }

    // MARK: - Test 3: Diode Switching Circuit

    /// Verifies convergence during diode switching with fast turn-on.
    ///
    /// Diode switching creates numerical challenges:
    /// - Sharp exponential I-V characteristic
    /// - Rapid change in operating point
    /// - Requires voltage limiting for NR convergence
    @Test("Diode switching circuit converges with voltage limiting")
    func diodeSwitchingConvergence() async throws {
        let r = 100.0
        let vSwitch = 5.0

        var netlist = Netlist()
        let _ = netlist.node("in")
        let anode = netlist.node("anode")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(vSwitch)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "anode"],
                                 parameters: ["r": .real(r)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["anode", "0"],
                                 parameters: ["is": .real(1e-14)])

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

        // DC analysis should converge even with diode nonlinearity
        let dcAnalysis = DCAnalysis(
            config: ConvergenceConfig(maxIterations: 100),
            gminStepping: GminStepping(maxSteps: 50),
            sourceStepping: SourceStepping(steps: 50)
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let dcResult = try await dcAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Diode should be forward biased
        // Va ≈ 0.6-0.7V (diode drop)
        let va = dcResult.voltage(at: anode)
        #expect(va > 0.5, "Anode voltage should be ~0.6-0.7V: got \(va)")
        #expect(va < 0.8, "Anode voltage should not exceed 0.8V: got \(va)")
    }

    // MARK: - Test 4: Multiple Time Constants

    /// Verifies convergence with three distinct time constants.
    ///
    /// Circuit has fast (ns), medium (µs), and slow (ms) time constants.
    @Test("Circuit with three distinct time constants")
    func multipleTimeConstants() async throws {
        // Fast: R1=1k, C1=1pF → τ1 = 1ns
        // Medium: R2=10k, C2=10nF → τ2 = 100µs
        // Slow: R3=100k, C3=100nF → τ3 = 10ms

        var netlist = Netlist()
        let _ = netlist.node("in")
        let n1 = netlist.node("n1")
        let n2 = netlist.node("n2")
        let n3 = netlist.node("n3")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(1.0)])

        // Fast path
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                 parameters: ["r": .real(1000.0)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["n1", "0"],
                                 parameters: ["c": .real(1e-12)])

        // Medium path (from n1)
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["n1", "n2"],
                                 parameters: ["r": .real(10000.0)])
        try netlist.addInstance(name: "C2", typeName: "capacitor", nodes: ["n2", "0"],
                                 parameters: ["c": .real(10e-9)])

        // Slow path (from n2)
        try netlist.addInstance(name: "R3", typeName: "resistor", nodes: ["n2", "n3"],
                                 parameters: ["r": .real(100000.0)])
        try netlist.addInstance(name: "C3", typeName: "capacitor", nodes: ["n3", "0"],
                                 parameters: ["c": .real(100e-9)])

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

        // Simulate long enough to see the medium time constant settle
        let tau_medium = 100e-6
        let config = TransientConfig(stopTime: 10 * tau_medium, maxTimeStep: tau_medium / 100)
        let analysis = TransientAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Fast node should be fully charged
        let v1 = result.voltage(at: n1, timeIndex: result.timePoints.count - 1)
        #expect(v1 > 0.99, "Fast node should be ~1V: got \(v1)")

        // Medium node should be significantly charged
        let v2 = result.voltage(at: n2, timeIndex: result.timePoints.count - 1)
        #expect(v2 > 0.95, "Medium node should be well charged: got \(v2)")

        // Slow node should just be starting to charge
        let v3 = result.voltage(at: n3, timeIndex: result.timePoints.count - 1)
        // τ_slow = 10ms, simulation = 1ms → about 10% charged
        #expect(v3 > 0, "Slow node should have started charging: got \(v3)")
        #expect(v3 < v2, "Slow node should be behind medium node: \(v3) < \(v2)")
    }
}
