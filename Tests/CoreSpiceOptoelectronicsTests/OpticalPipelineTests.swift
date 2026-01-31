import Testing
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceAnalysis
import CoreSpiceEvent
@testable import CoreSpiceOptoelectronics

/// End-to-end pipeline tests for optical circuits.
///
/// Validates the full flow: Netlist → CircuitIR → Compile → Bind → OpticalNetworkGraph → DC Analysis.
/// These tests verify that the Netlist optical API, OpticalNetworkGraphBuilder,
/// and the analysis engine work together correctly.
@Suite("Optical Pipeline E2E Tests")
struct OpticalPipelineTests {

    // MARK: - Helper

    /// Compiles a netlist with optoelectronic device support and builds the optical network graph.
    private func compileWithOptics(_ netlist: Netlist) throws -> (ExecutionPlan, [any BoundDevice]) {
        let ir = try netlist.build()
        let compiler = StandardCompiler()
        var plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.withOptoelectronics()
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

        // Build optical network graph from bound devices
        let graphBuilder = OpticalNetworkGraphBuilder()
        if let graph = graphBuilder.build(from: ir, devices: devices) {
            plan = ExecutionPlan(
                ir: plan.ir,
                topology: plan.topology,
                matrixStructure: plan.matrixStructure,
                deviceNames: plan.deviceNames,
                opticalNetwork: graph
            )
        }

        return (plan, devices)
    }

    /// Runs DC analysis on a netlist with optoelectronic support.
    private func runDCWithOptics(
        _ netlist: Netlist,
        config: ConvergenceConfig = ConvergenceConfig()
    ) async throws -> DCResult {
        let (plan, devices) = try compileWithOptics(netlist)
        let analysis = DCAnalysis(config: config)
        let solver = SparseLUSolver()
        let token = CancellationToken()
        return try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )
    }

    // MARK: - Netlist Optical Node API

    @Test("Netlist optical node resolution creates unique optical nodes")
    func netlistOpticalNodes() throws {
        var netlist = Netlist()
        let opt1 = netlist.opticalNode("opt1")
        let opt2 = netlist.opticalNode("opt2")
        let opt1again = netlist.opticalNode("opt1")

        #expect(opt1.id == opt1again.id, "Same name should resolve to same optical node")
        #expect(opt1.id != opt2.id, "Different names should resolve to different nodes")
        #expect(opt1.id >= 1, "Optical node IDs should start from 1 (0 is optical ground)")
    }

    @Test("Netlist addInstance with optical nodes populates Instance.opticalNodes")
    func netlistAddInstanceWithOptical() throws {
        var netlist = Netlist()
        let _ = netlist.branch()
        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["anode", "0"],
            parameters: ["v": .real(1.5)]
        )
        try netlist.addInstance(
            name: "LD1", typeName: "laser", nodes: ["anode", "0"],
            opticalNodes: ["opt_laser"],
            parameters: ["ith": .real(20e-3)]
        )

        let ir = try netlist.build()
        let laserInstance = ir.instances.first(where: { $0.name == "LD1" })
        #expect(laserInstance != nil)
        #expect(laserInstance!.opticalNodes.count == 1)
        #expect(laserInstance!.opticalNodes[0].id >= 1)
        #expect(ir.opticalNodes.count == 1)
    }

    @Test("Netlist optical node sharing across instances")
    func netlistOpticalNodeSharing() throws {
        var netlist = Netlist()
        let _ = netlist.branch()
        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["anode", "0"],
            parameters: ["v": .real(1.5)]
        )
        try netlist.addInstance(
            name: "LD1", typeName: "laser", nodes: ["anode", "0"],
            opticalNodes: ["opt_link"],
            parameters: ["ith": .real(20e-3)]
        )
        try netlist.addInstance(
            name: "PD1", typeName: "photodiode", nodes: ["pd_a", "0"],
            opticalNodes: ["opt_link"],
            parameters: ["resp": .real(0.8)]
        )

        let ir = try netlist.build()
        let laser = ir.instances.first(where: { $0.name == "LD1" })!
        let pd = ir.instances.first(where: { $0.name == "PD1" })!

        // Both should reference the same optical node
        #expect(laser.opticalNodes[0].id == pd.opticalNodes[0].id)
        // Only one unique optical node in the circuit
        #expect(ir.opticalNodes.count == 1)
    }

    // MARK: - OpticalNetworkGraphBuilder

    @Test("OpticalNetworkGraphBuilder constructs correct DAG for laser → PD")
    func graphBuilderLaserPD() throws {
        var netlist = Netlist()
        let _ = netlist.branch()
        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["anode", "0"],
            parameters: ["v": .real(1.5)]
        )
        try netlist.addInstance(
            name: "LD1", typeName: "laser", nodes: ["anode", "0"],
            opticalNodes: ["opt_link"],
            parameters: ["ith": .real(20e-3)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["pd_a", "0"],
            parameters: ["r": .real(1e3)]
        )
        try netlist.addInstance(
            name: "PD1", typeName: "photodiode", nodes: ["pd_a", "0"],
            opticalNodes: ["opt_link"],
            parameters: ["resp": .real(0.8)]
        )

        let (plan, _) = try compileWithOptics(netlist)

        #expect(plan.opticalNetwork != nil, "Should have optical network")
        let graph = plan.opticalNetwork!
        #expect(graph.evaluationOrder.count == 2, "Should have laser and PD in evaluation order")
        #expect(graph.opticalNodeCount >= 2, "Should have at least 2 optical nodes (ground + 1)")

        // First entry should be the laser (emitter, no optical inputs)
        let first = graph.evaluationOrder[0]
        #expect(first.inputNodes.isEmpty, "Emitter should have no optical inputs")
        #expect(!first.outputNodes.isEmpty, "Emitter should have optical output")
    }

    @Test("OpticalNetworkGraphBuilder constructs DAG for laser → waveguide → PD")
    func graphBuilderLaserWaveguidePD() throws {
        var netlist = Netlist()
        let _ = netlist.branch()
        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["anode", "0"],
            parameters: ["v": .real(1.5)]
        )
        try netlist.addInstance(
            name: "LD1", typeName: "laser", nodes: ["anode", "0"],
            opticalNodes: ["opt_laser_out"],
            parameters: ["ith": .real(20e-3)]
        )
        try netlist.addInstance(
            name: "WG1", typeName: "waveguide", nodes: [],
            opticalNodes: ["opt_laser_out", "opt_pd_in"],
            parameters: ["length": .real(0.01), "loss": .real(0.5)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["pd_a", "0"],
            parameters: ["r": .real(1e3)]
        )
        try netlist.addInstance(
            name: "PD1", typeName: "photodiode", nodes: ["pd_a", "0"],
            opticalNodes: ["opt_pd_in"],
            parameters: ["resp": .real(0.8)]
        )

        let (plan, _) = try compileWithOptics(netlist)

        #expect(plan.opticalNetwork != nil)
        let graph = plan.opticalNetwork!
        #expect(graph.evaluationOrder.count == 3, "Laser → waveguide → PD")
        #expect(graph.opticalNodeCount >= 3, "ground + laser_out + pd_in")
    }

    @Test("OpticalNetworkGraphBuilder returns nil for purely electrical circuit")
    func graphBuilderPurelyElectrical() throws {
        var netlist = Netlist()
        let _ = netlist.branch()
        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(5.0)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "0"],
            parameters: ["r": .real(1e3)]
        )

        let (plan, _) = try compileWithOptics(netlist)
        #expect(plan.opticalNetwork == nil, "No optical network for pure electrical circuit")
    }

    // MARK: - DC Analysis E2E

    @Test("Laser + PD + load resistor DC: photocurrent generates voltage")
    func laserPDLoadDC() async throws {
        // Circuit:
        //   V1(1.5V) → R_series(10Ω) → laser_a → LD1(cathode=GND) --[opt]-→ PD1(pd_out, GND) → R_load(1kΩ) → GND
        var netlist = Netlist()
        let _ = netlist.branch()  // V1
        let pdOut = netlist.node("pd_out")

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["vcc", "0"],
            parameters: ["v": .real(1.5)]
        )
        try netlist.addInstance(
            name: "R_series", typeName: "resistor", nodes: ["vcc", "laser_a"],
            parameters: ["r": .real(10.0)]
        )
        try netlist.addInstance(
            name: "LD1", typeName: "laser",
            nodes: ["laser_a", "0"],
            opticalNodes: ["opt_link"],
            parameters: [
                "ith": .real(20e-3),
                "slope_eff": .real(0.3),
                "is": .real(1e-14),
                "n": .real(2.0),
                "rs": .real(5.0)
            ]
        )
        try netlist.addInstance(
            name: "PD1", typeName: "photodiode",
            nodes: ["pd_out", "0"],
            opticalNodes: ["opt_link"],
            parameters: [
                "resp": .real(0.8),
                "idark": .real(1e-9),
                "is": .real(1e-14)
            ]
        )
        try netlist.addInstance(
            name: "R_load", typeName: "resistor", nodes: ["pd_out", "0"],
            parameters: ["r": .real(1e3)]
        )

        let config = ConvergenceConfig(
            reltol: 1e-3,
            vntol: 1e-4,
            maxIterations: 200,
            gmin: 1e-9
        )
        let result = try await runDCWithOptics(netlist, config: config)

        // Verify optical state exists
        #expect(result.opticalState != nil, "DC result should include optical state")

        if let optState = result.opticalState {
            // Find optical power (at any non-ground node)
            let maxOpticalPower = optState.signals.enumerated()
                .filter { $0.offset > 0 && $0.offset < optState.nodeCount }
                .map { $0.element.power }
                .max() ?? 0
            #expect(maxOpticalPower > 0, "Laser should emit optical power above threshold")
        }

        // PD output voltage: photocurrent through R_load
        let vPdOut = result.voltage(at: pdOut)
        #expect(abs(vPdOut) > 1e-6, "PD output should have measurable voltage from photocurrent")
    }

    @Test("LED + PD direct link DC: optical power propagates correctly")
    func ledPDDirectLinkDC() async throws {
        var netlist = Netlist()
        let _ = netlist.branch()  // V_led
        let pdOut = netlist.node("pd_out")

        try netlist.addInstance(
            name: "V_LED", typeName: "vsource", nodes: ["vcc", "0"],
            parameters: ["v": .real(2.0)]
        )
        try netlist.addInstance(
            name: "R_led", typeName: "resistor", nodes: ["vcc", "led_a"],
            parameters: ["r": .real(50.0)]
        )
        try netlist.addInstance(
            name: "LED1", typeName: "led",
            nodes: ["led_a", "0"],
            opticalNodes: ["opt_direct"],
            parameters: [
                "eta_ext": .real(0.1),
                "lambda": .real(850e-9),
                "is": .real(1e-14),
                "n": .real(2.0)
            ]
        )
        try netlist.addInstance(
            name: "PD1", typeName: "photodiode",
            nodes: ["pd_out", "0"],
            opticalNodes: ["opt_direct"],
            parameters: [
                "resp": .real(0.5),
                "idark": .real(1e-9),
                "is": .real(1e-14)
            ]
        )
        try netlist.addInstance(
            name: "R_tia", typeName: "resistor", nodes: ["pd_out", "0"],
            parameters: ["r": .real(10e3)]
        )

        let config = ConvergenceConfig(
            reltol: 1e-3,
            vntol: 1e-4,
            maxIterations: 200,
            gmin: 1e-9
        )
        let result = try await runDCWithOptics(netlist, config: config)

        #expect(result.opticalState != nil, "Should have optical state")

        if let optState = result.opticalState {
            let maxPower = optState.signals.enumerated()
                .filter { $0.offset > 0 && $0.offset < optState.nodeCount }
                .map { $0.element.power }
                .max() ?? 0
            #expect(maxPower > 0, "LED should emit optical power")
        }

        // Verify PD develops voltage across TIA resistor
        let vPd = result.voltage(at: pdOut)
        #expect(abs(vPd) > 1e-6, "PD should develop voltage from photocurrent")
    }

    @Test("Waveguide attenuates optical power in full pipeline")
    func waveguideLossDC() async throws {
        // Direct link: LD → PD
        var netlistDirect = Netlist()
        let _ = netlistDirect.branch()
        let pdDirect = netlistDirect.node("pd")

        try netlistDirect.addInstance(name: "V1", typeName: "vsource", nodes: ["vcc", "0"],
                                       parameters: ["v": .real(1.5)])
        try netlistDirect.addInstance(name: "RS", typeName: "resistor", nodes: ["vcc", "la"],
                                       parameters: ["r": .real(10.0)])
        try netlistDirect.addInstance(name: "LD1", typeName: "laser", nodes: ["la", "0"],
                                       opticalNodes: ["opt"],
                                       parameters: ["ith": .real(20e-3), "slope_eff": .real(0.3),
                                                     "is": .real(1e-14), "n": .real(2.0), "rs": .real(5.0)])
        try netlistDirect.addInstance(name: "PD1", typeName: "photodiode", nodes: ["pd", "0"],
                                       opticalNodes: ["opt"],
                                       parameters: ["resp": .real(0.8), "is": .real(1e-14)])
        try netlistDirect.addInstance(name: "RL", typeName: "resistor", nodes: ["pd", "0"],
                                       parameters: ["r": .real(1e3)])

        // With waveguide: LD → WG(10cm, 3dB/cm = 30dB loss) → PD
        var netlistWG = Netlist()
        let _ = netlistWG.branch()
        let pdWG = netlistWG.node("pd")

        try netlistWG.addInstance(name: "V1", typeName: "vsource", nodes: ["vcc", "0"],
                                   parameters: ["v": .real(1.5)])
        try netlistWG.addInstance(name: "RS", typeName: "resistor", nodes: ["vcc", "la"],
                                   parameters: ["r": .real(10.0)])
        try netlistWG.addInstance(name: "LD1", typeName: "laser", nodes: ["la", "0"],
                                   opticalNodes: ["opt_out"],
                                   parameters: ["ith": .real(20e-3), "slope_eff": .real(0.3),
                                                 "is": .real(1e-14), "n": .real(2.0), "rs": .real(5.0)])
        try netlistWG.addInstance(name: "WG1", typeName: "waveguide", nodes: [],
                                   opticalNodes: ["opt_out", "opt_in"],
                                   parameters: ["length": .real(0.1), "loss": .real(3.0)])
        try netlistWG.addInstance(name: "PD1", typeName: "photodiode", nodes: ["pd", "0"],
                                   opticalNodes: ["opt_in"],
                                   parameters: ["resp": .real(0.8), "is": .real(1e-14)])
        try netlistWG.addInstance(name: "RL", typeName: "resistor", nodes: ["pd", "0"],
                                   parameters: ["r": .real(1e3)])

        let config = ConvergenceConfig(reltol: 1e-3, vntol: 1e-4, maxIterations: 200, gmin: 1e-9)

        let directResult = try await runDCWithOptics(netlistDirect, config: config)
        let wgResult = try await runDCWithOptics(netlistWG, config: config)

        // Waveguide should reduce PD voltage (less photocurrent)
        let vDirect = abs(directResult.voltage(at: pdDirect))
        let vWG = abs(wgResult.voltage(at: pdWG))
        #expect(vDirect > 0, "Direct link PD should have voltage")
        #expect(vWG < vDirect, "Waveguide should attenuate, reducing PD voltage")
    }

    // MARK: - Regression

    @Test("Electrical-only circuit through optoelectronic compile path works correctly")
    func electricalOnlyRegression() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                 parameters: ["v": .real(5.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                 parameters: ["r": .real(1e3)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "0"],
                                 parameters: ["r": .real(1e3)])

        let result = try await runDCWithOptics(netlist)

        #expect(result.opticalState == nil, "No optical state for pure electrical")
        let vMid = result.voltage(at: mid)
        #expect(abs(vMid - 2.5) < 1e-3, "Voltage divider should give 2.5V, got \(vMid)")
    }
}
