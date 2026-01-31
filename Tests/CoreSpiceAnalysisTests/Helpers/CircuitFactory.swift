import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

/// Reusable circuit construction helpers for integration tests.
/// Each method builds a circuit using the Netlist builder, compiles it,
/// and returns (ExecutionPlan, [BoundDevice], key nodes).
enum CircuitFactory {

    // MARK: - Common compile + bind

    /// Compile a netlist into an execution plan and bound devices.
    static func compile(_ netlist: Netlist) throws -> (ExecutionPlan, [any BoundDevice]) {
        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }
        return (plan, devices)
    }

    /// Run DC analysis on a netlist and return the result.
    static func runDC(
        _ netlist: Netlist,
        config: ConvergenceConfig = ConvergenceConfig(),
        gminStepping: GminStepping = GminStepping(),
        sourceStepping: SourceStepping = SourceStepping()
    ) async throws -> DCResult {
        let (plan, devices) = try compile(netlist)
        let analysis = DCAnalysis(config: config, gminStepping: gminStepping, sourceStepping: sourceStepping)
        let solver = SparseLUSolver()
        let token = CancellationToken()
        return try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )
    }

    /// Run AC analysis on a netlist and return the result.
    static func runAC(
        _ netlist: Netlist,
        sweep: FrequencySweep,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    ) async throws -> ACResult {
        let (plan, devices) = try compile(netlist)
        let analysis = ACAnalysis(sweep: sweep, dcConfig: dcConfig)
        let solver = SparseLUSolver()
        let token = CancellationToken()
        return try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )
    }

    /// Run transient analysis on a netlist and return the result.
    static func runTransient(
        _ netlist: Netlist,
        config: TransientConfig,
        convergenceConfig: ConvergenceConfig = ConvergenceConfig()
    ) async throws -> TransientResult {
        let (plan, devices) = try compile(netlist)
        let analysis = TransientAnalysis(config: config, convergenceConfig: convergenceConfig)
        let solver = SparseLUSolver()
        let token = CancellationToken()
        return try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )
    }

    /// Convergence config with higher Gmin for nonlinear circuits.
    /// The undamped NR solver needs help with BJT/MOSFET circuits.
    static let nonlinearConfig = ConvergenceConfig(
        reltol: 1e-3,
        vntol: 1e-4,
        maxIterations: 200,
        gmin: 1e-6
    )

    // MARK: - Resistive Divider

    /// V1(v) -> R1(r1) -> mid -> R2(r2) -> GND
    /// Returns (netlist, mid node)
    static func resistiveDivider(v: Double, r1: Double, r2: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let _ = netlist.branch() // V1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(v)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                  parameters: ["r": .real(r1)])
        try! netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "0"],
                                  parameters: ["r": .real(r2)])
        return (netlist, mid)
    }

    // MARK: - RC Lowpass

    /// V1(v, ac) -> R(r) -> out -> C(c) -> GND
    /// Returns (netlist, out node)
    static func rcLowpass(v: Double = 1.0, ac: Double = 1.0, r: Double, c: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(v), "ac": .real(ac)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                  parameters: ["r": .real(r)])
        try! netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                  parameters: ["c": .real(c)])
        return (netlist, out)
    }

    // MARK: - RC Highpass

    /// V1(v, ac) -> C(c) -> out -> R(r) -> GND
    static func rcHighpass(v: Double = 1.0, ac: Double = 1.0, r: Double, c: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(v), "ac": .real(ac)])
        try! netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["in", "out"],
                                  parameters: ["c": .real(c)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                                  parameters: ["r": .real(r)])
        return (netlist, out)
    }

    // MARK: - RL Highpass

    /// V1(ac) -> R(r) -> out -> L(l) -> GND
    /// At low freq L is short → V(out)=0; at high freq L is open → V(out)=V(in)
    static func rlHighpass(v: Double = 0.0, ac: Double = 1.0, r: Double, l: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(v), "ac": .real(ac)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                  parameters: ["r": .real(r)])
        try! netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["out", "0"],
                                  parameters: ["l": .real(l)])
        return (netlist, out)
    }

    // MARK: - RLC Series

    /// V1(ac) -> R(r) -> n1 -> L(l) -> n2 -> C(c) -> GND, output across C
    static func rlcSeries(v: Double = 0.0, ac: Double = 1.0, r: Double, l: Double, c: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("n1")
        let out = netlist.node("n2")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(v), "ac": .real(ac)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                  parameters: ["r": .real(r)])
        try! netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["n1", "n2"],
                                  parameters: ["l": .real(l)])
        try! netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["n2", "0"],
                                  parameters: ["c": .real(c)])
        return (netlist, out)
    }

    // MARK: - Diode Circuit

    /// V1(v) -> R1(r) -> anode -> D1 -> GND
    static func diodeCircuit(v: Double, r: Double, diodeParams: [String: ParameterValue] = [:]) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let anode = netlist.node("anode")
        let _ = netlist.branch() // V1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(v)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "anode"],
                                  parameters: ["r": .real(r)])
        try! netlist.addInstance(name: "D1", typeName: "diode", nodes: ["anode", "0"],
                                  parameters: diodeParams)
        return (netlist, anode)
    }

    // MARK: - BJT Common Emitter

    /// Vcc -> Rc -> collector, Vbb -> Rb -> base, emitter -> GND
    /// Returns (netlist, collector node, base node)
    static func bjtCommonEmitter(
        vcc: Double, rc: Double, vbb: Double, rb: Double,
        isNPN: Bool = true,
        bjtParams: [String: ParameterValue] = [:]
    ) -> (Netlist, Node, Node) {
        var netlist = Netlist()
        let _ = netlist.node("vcc")
        let _ = netlist.node("vbb")
        let col = netlist.node("col")
        let base = netlist.node("base")
        let _ = netlist.branch() // VCC
        let _ = netlist.branch() // VBB
        try! netlist.addInstance(name: "VCC", typeName: "vsource", nodes: ["vcc", "0"],
                                  parameters: ["v": .real(vcc)])
        try! netlist.addInstance(name: "VBB", typeName: "vsource", nodes: ["vbb", "0"],
                                  parameters: ["v": .real(vbb)])
        try! netlist.addInstance(name: "RC", typeName: "resistor", nodes: ["vcc", "col"],
                                  parameters: ["r": .real(rc)])
        try! netlist.addInstance(name: "RB", typeName: "resistor", nodes: ["vbb", "base"],
                                  parameters: ["r": .real(rb)])
        let typeName = isNPN ? "npn" : "pnp"
        try! netlist.addInstance(name: "Q1", typeName: typeName, nodes: ["col", "base", "0"],
                                  parameters: bjtParams)
        return (netlist, col, base)
    }

    // MARK: - NMOS Common Source

    /// Vdd -> Rd -> drain, Vgs -> gate, source -> GND
    /// Returns (netlist, drain node)
    static func nmosCommonSource(
        vdd: Double, rd: Double, vgs: Double,
        mosParams: [String: ParameterValue] = [:]
    ) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("vdd")
        let _ = netlist.node("gate")
        let drain = netlist.node("drain")
        let _ = netlist.branch() // VDD
        let _ = netlist.branch() // VGS
        try! netlist.addInstance(name: "VDD", typeName: "vsource", nodes: ["vdd", "0"],
                                  parameters: ["v": .real(vdd)])
        try! netlist.addInstance(name: "VGS", typeName: "vsource", nodes: ["gate", "0"],
                                  parameters: ["v": .real(vgs)])
        try! netlist.addInstance(name: "RD", typeName: "resistor", nodes: ["vdd", "drain"],
                                  parameters: ["r": .real(rd)])
        try! netlist.addInstance(name: "M1", typeName: "nmos_l1", nodes: ["drain", "gate", "0"],
                                  parameters: mosParams)
        return (netlist, drain)
    }

    // MARK: - PMOS Common Source

    /// GND -> Rd -> drain, Vsg (gate below Vdd), source -> Vdd
    /// Returns (netlist, drain node)
    static func pmosCommonSource(
        vdd: Double, rd: Double, vgate: Double,
        mosParams: [String: ParameterValue] = [:]
    ) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("vdd")
        let _ = netlist.node("gate")
        let drain = netlist.node("drain")
        let _ = netlist.branch() // VDD
        let _ = netlist.branch() // VGATE
        try! netlist.addInstance(name: "VDD", typeName: "vsource", nodes: ["vdd", "0"],
                                  parameters: ["v": .real(vdd)])
        try! netlist.addInstance(name: "VGATE", typeName: "vsource", nodes: ["gate", "0"],
                                  parameters: ["v": .real(vgate)])
        try! netlist.addInstance(name: "RD", typeName: "resistor", nodes: ["drain", "0"],
                                  parameters: ["r": .real(rd)])
        try! netlist.addInstance(name: "M1", typeName: "pmos_l1", nodes: ["drain", "gate", "vdd"],
                                  parameters: mosParams)
        return (netlist, drain)
    }

    // MARK: - VCVS Circuit

    /// V1 -> R1 -> ctrl+ (ctrl- = GND), E1(gain) out+ -> Rload -> out-(GND)
    static func vcvsCircuit(vin: Double, r1: Double, gain: Double, rload: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // E1 (VCVS)
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(vin)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "0"],
                                  parameters: ["r": .real(r1)])
        try! netlist.addInstance(name: "E1", typeName: "vcvs", nodes: ["out", "0", "in", "0"],
                                  parameters: ["e": .real(gain)])
        try! netlist.addInstance(name: "RL", typeName: "resistor", nodes: ["out", "0"],
                                  parameters: ["r": .real(rload)])
        return (netlist, out)
    }

    // MARK: - VCCS Circuit

    /// V1 -> R1 -> ctrl+ (ctrl- = GND), G1(g) out+ -> Rload -> out-(GND)
    static func vccsCircuit(vin: Double, r1: Double, g: Double, rload: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(vin)])
        try! netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "0"],
                                  parameters: ["r": .real(r1)])
        try! netlist.addInstance(name: "G1", typeName: "vccs", nodes: ["out", "0", "in", "0"],
                                  parameters: ["g": .real(g)])
        try! netlist.addInstance(name: "RL", typeName: "resistor", nodes: ["out", "0"],
                                  parameters: ["r": .real(rload)])
        return (netlist, out)
    }

    // MARK: - CCVS Circuit

    /// V1 -> R_sense -> sense+ (sense- = GND), H1(h) out+ -> Rload -> out-(GND)
    static func ccvsCircuit(vin: Double, rSense: Double, h: Double, rload: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("sense")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // H1 sense branch
        let _ = netlist.branch() // H1 output branch
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(vin)])
        try! netlist.addInstance(name: "RS", typeName: "resistor", nodes: ["in", "sense"],
                                  parameters: ["r": .real(rSense)])
        // CCVS: [pos_out, neg_out, pos_sense, neg_sense]
        try! netlist.addInstance(name: "H1", typeName: "ccvs", nodes: ["out", "0", "sense", "0"],
                                  parameters: ["h": .real(h)])
        try! netlist.addInstance(name: "RL", typeName: "resistor", nodes: ["out", "0"],
                                  parameters: ["r": .real(rload)])
        return (netlist, out)
    }

    // MARK: - CCCS Circuit

    /// V1 -> R_sense -> sense+ (sense- = GND), F1(f) out+ -> Rload -> out-(GND)
    static func cccsCircuit(vin: Double, rSense: Double, f: Double, rload: Double) -> (Netlist, Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("sense")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // F1 sense branch
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(vin)])
        try! netlist.addInstance(name: "RS", typeName: "resistor", nodes: ["in", "sense"],
                                  parameters: ["r": .real(rSense)])
        // Grounding the sense node to complete the current path
        try! netlist.addInstance(name: "R_GND", typeName: "resistor", nodes: ["sense", "0"],
                                  parameters: ["r": .real(1e-3)]) // small R to ground
        // CCCS: [pos_out, neg_out, pos_sense, neg_sense]
        try! netlist.addInstance(name: "F1", typeName: "cccs", nodes: ["out", "0", "sense", "0"],
                                  parameters: ["f": .real(f)])
        try! netlist.addInstance(name: "RL", typeName: "resistor", nodes: ["out", "0"],
                                  parameters: ["r": .real(rload)])
        return (netlist, out)
    }

    // MARK: - Series Resistors

    /// V1(v) -> R1 -> n1 -> R2 -> n2 -> ... -> Rn -> GND
    /// Returns (netlist, [intermediate nodes])
    static func seriesResistors(v: Double, resistances: [Double]) -> (Netlist, [Node]) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.branch() // V1
        try! netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                  parameters: ["v": .real(v)])

        var nodes: [Node] = []
        for (i, r) in resistances.enumerated() {
            let fromName = i == 0 ? "in" : "n\(i)"
            let toName = i == resistances.count - 1 ? "0" : "n\(i + 1)"
            if toName != "0" {
                let n = netlist.node(toName)
                nodes.append(n)
            }
            try! netlist.addInstance(name: "R\(i + 1)", typeName: "resistor",
                                      nodes: [fromName, toName],
                                      parameters: ["r": .real(r)])
        }
        return (netlist, nodes)
    }
}
