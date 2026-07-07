import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Pole-Zero Integration Tests")
struct PoleZeroIntegrationTests {

    // MARK: - Helper

    private func runPoleZero(netlist: Netlist, outputNode: Node, inputSourceName: String = "V1") async throws -> PoleZeroResult {
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let analysis = PoleZeroAnalysis(
            outputNode: outputNode,
            inputSourceName: inputSourceName
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()
        return try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )
    }

    // MARK: - I5: Single RC pole equals the exact analytic value

    @Test("I5: Single RC pole equals -1/(RC)")
    func singleRCPoleExact() async throws {
        // V1 -> R(1k) -> out -> C(1u) -> GND. H = 1/(1+sRC), single pole at -1/(RC).
        let r = 1000.0, c = 1e-6
        let (netlist, out) = try CircuitFactory.rcLowpass(r: r, c: c)
        let result = try await runPoleZero(netlist: netlist, outputNode: out)
        #expect(result.poles.count == 1, "single RC should have 1 pole, got \(result.poles.count)")
        let p = result.poles[0]
        let expectedRadPerSec = -1.0 / (r * c)  // -1000 rad/s
        #expect(abs(p.imag) < abs(expectedRadPerSec) * 0.01, "pole should be real, imag=\(p.imag)")
        #expect(abs(p.real - expectedRadPerSec) / abs(expectedRadPerSec) < 0.01,
                "pole should be \(expectedRadPerSec) rad/s, got \(p.real)")
        #expect(abs(result.dcGain - 1.0) < 0.01, "DC gain should be 1, got \(result.dcGain)")
    }

    // MARK: - I4: Two-Stage RC Filter (2 Real Poles)

    @Test("I4: Two-stage RC filter has two distinct real poles")
    func twoStageRCPoles() async throws {
        // V1 → R1(1kΩ) → mid → C1(1µF) → GND, mid → R2(1kΩ) → out → C2(1µF) → GND
        // Two cascaded RC stages with interaction
        // Poles are NOT at -1/(R1C1) and -1/(R2C2) due to loading effects
        // But both should be real and negative
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("mid")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["mid", "0"],
                                parameters: ["c": .real(1e-6)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C2", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let result = try await runPoleZero(netlist: netlist, outputNode: out)

        // Should have 2 poles
        #expect(result.poles.count == 2,
                "Two-stage RC should have 2 poles, got \(result.poles.count)")

        // Both poles should be real (imaginary part near zero) and negative
        for pole in result.poles {
            #expect(pole.real < 0,
                    "Passive circuit pole should have negative real part, got \(pole.real)")
            #expect(abs(pole.imag) < abs(pole.real) * 0.1,
                    "RC-only circuit should have real poles, imag=\(pole.imag)")
        }

        // The two poles should be distinct
        let sortedPoles = result.poles.sorted { $0.real < $1.real }
        #expect(abs(sortedPoles[0].real - sortedPoles[1].real) > 100,
                "Two poles should be distinct: \(sortedPoles[0].real) vs \(sortedPoles[1].real)")

        // DC gain should be 1.0 (both Cs open at DC → full voltage passes)
        #expect(abs(result.dcGain - 1.0) < 0.01,
                "DC gain should be 1.0, got \(result.dcGain)")
    }

    // MARK: - I5: RLC Circuit with Zeros

    @Test("I5: RLC circuit with transmission zeros")
    func rlcWithZeros() async throws {
        // V1 → R(100Ω) → out, out → L(1mH) → GND, out → C(1µF) → GND
        // Output is across parallel L-C from out to GND
        // Transfer function has zeros when L-C resonates (impedance → 0)
        // Zero at ω = 1/√(LC) where parallel LC shorts to ground
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(100)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["out", "0"],
                                parameters: ["l": .real(1e-3)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let result = try await runPoleZero(netlist: netlist, outputNode: out)

        // Should have poles (from LC resonance)
        #expect(result.poles.count >= 2,
                "RLC should have at least 2 poles, got \(result.poles.count)")

        // All poles should have negative real part (passive circuit → stable)
        for pole in result.poles {
            #expect(pole.real < 0,
                    "Passive circuit: pole real part should be negative, got \(pole.real)")
        }

        // DC gain: at DC, inductor is short circuit to GND → V(out) = 0 → gain = 0
        #expect(abs(result.dcGain) < 0.01,
                "DC gain should be ~0 (inductor shorts output at DC), got \(result.dcGain)")
    }

    // MARK: - I6: DC Gain Verification

    @Test("I6: Pole-zero DC gain matches transfer function analysis")
    func dcGainVerification() async throws {
        // Resistive divider: V1(5V) → R1(1kΩ) → out → R2(3kΩ) → GND
        // DC gain = R2/(R1+R2) = 3000/4000 = 0.75
        // Add a capacitor to have an interesting pole
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(5.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(3000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let result = try await runPoleZero(netlist: netlist, outputNode: out)

        // DC gain should match resistive divider ratio
        #expect(abs(result.dcGain - 0.75) < 0.01,
                "DC gain should be R2/(R1+R2) = 0.75, got \(result.dcGain)")

        // Should have one pole from the RC combination
        #expect(result.poles.count >= 1,
                "Should have at least 1 pole from RC, got \(result.poles.count)")

        // Pole should be at approximately -1/(R_parallel × C)
        // R_parallel = R1‖R2 = 750Ω, pole at -1/(750 × 1e-6) = -1333 rad/s
        let expectedPole = -1.0 / (750.0 * 1e-6)
        if let pole = result.poles.first {
            let relError = abs(pole.real - expectedPole) / abs(expectedPole)
            #expect(relError < 0.1,
                    "Pole should be near \(expectedPole), got \(pole.real)")
        }
    }
}
