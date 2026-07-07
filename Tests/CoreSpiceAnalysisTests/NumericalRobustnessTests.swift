import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

/// Tests for numerical robustness under extreme conditions.
///
/// Verifies that the simulator handles:
/// 1. Very small capacitances (attofarad range)
/// 2. Very large resistances (teraohm range)
/// 3. Near-zero voltage differences
/// 4. Mixed-scale circuits
/// 5. Long simulations without drift
@Suite("Numerical Robustness Tests")
struct NumericalRobustnessTests {

    // MARK: - Test 1: Very Small Capacitance

    /// Verifies stability with extremely small capacitance (1 aF = 10^-18 F).
    ///
    /// Numerical challenge:
    /// - Geq = C/dt can become very small
    /// - Risk of matrix ill-conditioning
    /// - Must maintain solution accuracy
    @Test("Very small capacitance (1 aF) simulation stability")
    func verySmallCapacitance() async throws {
        let r = 1e9           // 1 GΩ
        let c = 1e-18         // 1 aF (attofarad)
        let tau = r * c       // 1 µs (surprisingly reasonable)

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                 parameters: ["r": .real(r)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                 parameters: ["c": .real(c)])

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

        let config = TransientConfig(stopTime: 5 * tau, maxTimeStep: tau / 10)
        let analysis = TransientAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Should have multiple time points (not collapsed)
        #expect(result.timePoints.count > 5, "Should have multiple time points")

        // All voltages should be finite
        for i in 0..<result.timePoints.count {
            let v = try result.voltage(at: out, timeIndex: i)
            #expect(v.isFinite, "Voltage should be finite at t=\(result.timePoints[i])")
        }

        // Final voltage should approach input
        let vFinal = try result.voltage(at: out, timeIndex: result.timePoints.count - 1)
        #expect(vFinal > 0.99, "Capacitor should charge to ~1V: got \(vFinal)")
    }

    // MARK: - Test 2: Very Large Resistance

    /// Verifies stability with large resistance (100 MΩ = 10^8 Ω).
    ///
    /// Note: GMIN (~1e-12 S) affects results at very high resistances.
    /// We use 100 MΩ (G = 1e-8 S >> GMIN) to minimize GMIN effects.
    ///
    /// Numerical challenge:
    /// - Conductance G = 1/R is small but still >> GMIN
    /// - Must maintain numerical stability
    @Test("Very large resistance (100 MΩ) DC convergence")
    func veryLargeResistance() async throws {
        let r = 1e8  // 100 MΩ (conductance = 1e-8 S >> GMIN ~1e-12 S)
        let v = 1.0

        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(v)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                 parameters: ["r": .real(r)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "0"],
                                 parameters: ["r": .real(r)])

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

        let dcAnalysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await dcAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Should get voltage divider result
        // Note: GMIN (~1e-12 S) causes small deviation at high resistances
        let vMid = result.voltage(at: mid)
        let expected = v / 2.0

        // Allow 0.01% tolerance due to GMIN effect
        #expect(abs(vMid - expected) / expected < 1e-4,
                "Voltage divider should give ~0.5V: got \(vMid)")
    }

    // MARK: - Test 3: Near-Zero Voltage Difference

    /// Verifies precision with very small voltage differences.
    ///
    /// Numerical challenge:
    /// - Subtraction of nearly equal numbers causes precision loss
    /// - Device models may have issues near zero bias
    @Test("Near-zero voltage precision (µV level)")
    func nearZeroVoltageDifference() async throws {
        // Create a voltage divider with nearly equal resistors
        let r1 = 1000.000
        let r2 = 1000.001  // Slightly different
        let v = 1.0

        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(v)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                 parameters: ["r": .real(r1)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "0"],
                                 parameters: ["r": .real(r2)])

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

        let dcAnalysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await dcAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Expected: V_mid = V * R2 / (R1 + R2)
        let expected = v * r2 / (r1 + r2)
        let vMid = result.voltage(at: mid)

        // Difference from exactly 0.5V should be tiny
        let diffFrom05 = abs(vMid - 0.5)
        #expect(diffFrom05 < 1e-6, "Voltage should be very close to 0.5V: got \(vMid)")

        // Should resolve the small difference
        let relError = abs(vMid - expected) / expected
        #expect(relError < 1e-9, "Should resolve µV-level differences: relative error = \(relError)")
    }

    // MARK: - Test 4: Mixed Scale Circuit

    /// Verifies stability with mixed µA currents and GΩ resistances.
    ///
    /// Numerical challenge:
    /// - Orders of magnitude difference between quantities
    /// - Scaling issues in matrix assembly
    @Test("Mixed scale: µA currents with GΩ resistances")
    func mixedScaleCircuit() async throws {
        let rLarge = 1e9     // 1 GΩ
        let rSmall = 1.0     // 1 Ω
        let v = 1.0

        // Circuit: V -> R_large -> node1 -> R_small -> GND
        // Current ≈ 1V / 1GΩ ≈ 1 nA
        // V(node1) ≈ R_small * I ≈ 1V * 1Ω / 1GΩ ≈ 1 nV

        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(v)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                 parameters: ["r": .real(rLarge)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "0"],
                                 parameters: ["r": .real(rSmall)])

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

        let dcAnalysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await dcAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Expected: V_mid = V * R_small / (R_large + R_small) ≈ 1e-9 V
        let expected = v * rSmall / (rLarge + rSmall)
        let vMid = result.voltage(at: mid)

        #expect(vMid.isFinite, "Voltage should be finite")
        #expect(abs(vMid - expected) / expected < 0.01,
                "Should resolve nV-level voltage: expected \(expected), got \(vMid)")
    }

    // MARK: - Test 5: Long Simulation Stability

    /// Verifies no drift or accumulation errors in long simulations.
    ///
    /// Numerical challenge:
    /// - Floating point errors can accumulate
    /// - Energy conservation should be maintained
    @Test("Long simulation stability (no drift)")
    func longSimulationStability() async throws {
        // Simple RC circuit with known steady state
        let r = 1000.0
        let c = 1e-6
        let v = 1.0
        let tau = r * c  // 1 ms

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(v)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                 parameters: ["r": .real(r)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                 parameters: ["c": .real(c)])

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

        // Run for 100 time constants - well beyond transient
        let config = TransientConfig(stopTime: 100 * tau, maxTimeStep: tau / 10)
        let analysis = TransientAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Check that voltage stays at steady state without drift
        // Sample at multiple points in the "steady state" region (t > 10τ)
        var steadyStateVoltages: [Double] = []
        for (i, t) in result.timePoints.enumerated() {
            if t > 10 * tau {
                let voltage = try result.voltage(at: out, timeIndex: i)
                steadyStateVoltages.append(voltage)
            }
        }

        #expect(steadyStateVoltages.count > 10, "Should have multiple steady-state samples")

        // All should be very close to 1V
        let minV = steadyStateVoltages.min()!
        let maxV = steadyStateVoltages.max()!
        let spread = maxV - minV

        #expect(spread < 1e-6, "Steady state should be stable: spread = \(spread)")
        #expect(abs(minV - 1.0) < 1e-6, "Steady state should be at 1V: min = \(minV)")
    }

    // MARK: - Test 6: Degenerate Geometry (Zero Length)

    /// Verifies handling of nearly singular conditions.
    @Test("Circuit with very small component values")
    func smallComponentValues() async throws {
        // Very small resistor (near short circuit)
        let r_tiny = 1e-6   // 1 µΩ
        let r_normal = 1000.0
        let v = 1.0

        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let _ = netlist.branch()

        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(v)])
        try netlist.addInstance(name: "R_tiny", typeName: "resistor", nodes: ["in", "mid"],
                                 parameters: ["r": .real(r_tiny)])
        try netlist.addInstance(name: "R_norm", typeName: "resistor", nodes: ["mid", "0"],
                                 parameters: ["r": .real(r_normal)])

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

        let dcAnalysis = DCAnalysis()
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await dcAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // V_mid should be almost exactly V_in (tiny voltage drop across R_tiny)
        let vMid = result.voltage(at: mid)
        let expected = v * r_normal / (r_tiny + r_normal)

        #expect(abs(vMid - expected) < 1e-6, "Should handle near-short circuit: got \(vMid)")
        #expect(vMid > 0.999999, "V_mid should be nearly V_in: got \(vMid)")
    }
}
