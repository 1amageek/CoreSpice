import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Sensitivity Analysis Tests")
struct SensitivityTests {

    /// Resistive voltage divider: V1(5V) -> R1(1kΩ) -> out -> R2(1kΩ) -> GND
    /// V(out) = V * R2 / (R1 + R2) = 2.5V
    ///
    /// Analytical sensitivities:
    ///   dV(out)/dR1 = -V * R2 / (R1 + R2)^2 = -5 * 1000 / 4e6 = -1.25e-3
    ///   dV(out)/dR2 =  V * R1 / (R1 + R2)^2 =  5 * 1000 / 4e6 = +1.25e-3
    @Test func resistiveDividerSensitivity() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(5.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(1000)]
        )

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

        let sensAnalysis = SensitivityAnalysis(outputNode: out)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await sensAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Baseline value should be 2.5V
        #expect(abs(result.baselineValue - 2.5) < 1e-6)

        // Find R1 sensitivity
        let r1Sens = result.sensitivities.first(where: {
            $0.deviceName == "R1" && $0.parameterName == "r"
        })
        #expect(r1Sens != nil)
        // dV/dR1 = -V*R2/(R1+R2)^2 = -5*1000/4e6 = -1.25e-3
        #expect(abs(r1Sens!.sensitivity - (-1.25e-3)) < 1e-5)

        // Find R2 sensitivity
        let r2Sens = result.sensitivities.first(where: {
            $0.deviceName == "R2" && $0.parameterName == "r"
        })
        #expect(r2Sens != nil)
        // dV/dR2 = V*R1/(R1+R2)^2 = 5*1000/4e6 = +1.25e-3
        #expect(abs(r2Sens!.sensitivity - 1.25e-3) < 1e-5)
    }

    /// Asymmetric divider: V1(10V) -> R1(1kΩ) -> out -> R2(3kΩ) -> GND
    /// V(out) = 10 * 3000 / 4000 = 7.5V
    ///
    /// dV(out)/dR1 = -V * R2 / (R1 + R2)^2 = -10 * 3000 / 16e6 = -1.875e-3
    /// dV(out)/dR2 =  V * R1 / (R1 + R2)^2 =  10 * 1000 / 16e6 = +6.25e-4
    @Test func asymmetricDividerSensitivity() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(10.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(3000)]
        )

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

        let sensAnalysis = SensitivityAnalysis(outputNode: out)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await sensAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Baseline: V(out) = 7.5V
        #expect(abs(result.baselineValue - 7.5) < 1e-6)

        // dV/dR1 = -10 * 3000 / 16e6 = -1.875e-3
        let r1Sens = result.sensitivities.first(where: {
            $0.deviceName == "R1" && $0.parameterName == "r"
        })
        #expect(r1Sens != nil)
        #expect(abs(r1Sens!.sensitivity - (-1.875e-3)) < 1e-5)

        // dV/dR2 = 10 * 1000 / 16e6 = 6.25e-4
        let r2Sens = result.sensitivities.first(where: {
            $0.deviceName == "R2" && $0.parameterName == "r"
        })
        #expect(r2Sens != nil)
        #expect(abs(r2Sens!.sensitivity - 6.25e-4) < 1e-5)
    }

    /// Normalized sensitivity should reflect relative changes.
    /// For symmetric divider: normalized sensitivity of R1 = (dV/dR1 * R1) / V(out)
    /// = (-1.25e-3 * 1000) / 2.5 = -0.5
    @Test func normalizedSensitivity() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(5.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(1000)]
        )

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

        let sensAnalysis = SensitivityAnalysis(outputNode: out)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await sensAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // Normalized sensitivity of R1: (dV/dR1 * R1) / V(out) = -0.5
        let r1Sens = result.sensitivities.first(where: {
            $0.deviceName == "R1" && $0.parameterName == "r"
        })
        #expect(r1Sens != nil)
        #expect(abs(r1Sens!.normalizedSensitivity - (-0.5)) < 0.01)

        // Normalized sensitivity of R2: (dV/dR2 * R2) / V(out) = +0.5
        let r2Sens = result.sensitivities.first(where: {
            $0.deviceName == "R2" && $0.parameterName == "r"
        })
        #expect(r2Sens != nil)
        #expect(abs(r2Sens!.normalizedSensitivity - 0.5) < 0.01)
    }

    /// Voltage source sensitivity: dV(out)/dV = R2/(R1+R2) = 0.5
    @Test func voltageSourceSensitivity() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(5.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1000)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(1000)]
        )

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

        let sensAnalysis = SensitivityAnalysis(outputNode: out)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await sensAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // dV(out)/dVs = R2/(R1+R2) = 0.5
        let vSens = result.sensitivities.first(where: {
            $0.deviceName == "V1" && $0.parameterName == "v"
        })
        #expect(vSens != nil)
        #expect(abs(vSens!.sensitivity - 0.5) < 1e-4)
    }
}
