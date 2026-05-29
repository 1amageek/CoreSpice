import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

/// Regressions for the independent current-source DC behavior, validated
/// against ngspice in validation/gate.py:
/// - Sign: SPICE draws current from the positive node and injects it into the
///   negative node, so `I1 out 0 1mA` into a 1k resistor gives V(out) = -1V.
/// - A current source driving an initially-off MOSFET must reach the real
///   operating point (the diode-connected mirror reference), not collapse to a
///   degenerate all-off solution.
@Suite("Current source convention")
struct CurrentSourceConventionTests {

    @Test("DC current source sign matches SPICE convention")
    func currentSourceDCSign() async throws {
        // I1 out 0 1mA, R1 out 0 1k -> V(out) = -I*R = -1V.
        var netlist = Netlist()
        let out = netlist.node("out")
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["out", "0"],
                                parameters: ["i": .real(1e-3)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1000)])

        let result = try await CircuitFactory.runDC(netlist)
        let v = result.voltage(at: out)
        #expect(abs(v - (-1.0)) < 1e-6,
                "V(out) should be -1V (SPICE current source sign), got \(v)")
    }

    @Test("Current source drives a diode-connected MOSFET to its operating point",
          .timeLimit(.minutes(1)))
    func currentMirrorReferenceConverges() async throws {
        // VDD=3.3, Iref(20uA) vdd->d, M1 diode-connected NMOS. The 20uA must
        // forward-bias M1 to Vgs ~ 0.83V; a degenerate all-off solution gives 0V.
        var netlist = Netlist()
        let _ = netlist.node("vdd")
        let d = netlist.node("d")
        let _ = netlist.branch() // VDD
        try netlist.addInstance(name: "VDD", typeName: "vsource", nodes: ["vdd", "0"],
                                parameters: ["v": .real(3.3)])
        try netlist.addInstance(name: "Iref", typeName: "isource", nodes: ["vdd", "d"],
                                parameters: ["i": .real(20e-6)])
        try netlist.addInstance(name: "M1", typeName: "nmos_l1", nodes: ["d", "d", "0", "0"],
                                parameters: ["vto": .real(0.7), "kp": .real(110e-6),
                                             "w": .real(20e-6), "l": .real(1e-6)])

        let result = try await CircuitFactory.runDC(netlist)
        let v = result.voltage(at: d)
        #expect(v > 0.6 && v < 1.0,
                "Diode-connected MOSFET driven by 20uA should bias ~0.83V, got \(v)")
    }
}
