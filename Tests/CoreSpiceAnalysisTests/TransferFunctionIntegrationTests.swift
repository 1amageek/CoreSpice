import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Transfer Function Integration Tests")
struct TransferFunctionIntegrationTests {

    // MARK: - D2: RC Filter Transfer Function

    @Test("D2: RC lowpass filter transfer function at DC")
    func rcFilterTransferFunction() async throws {
        // V1(1V) → R(1kΩ) → out → C(1µF) → GND
        // At DC: C is open circuit → gain = 1.0
        // Zin = R + ∞ (C open) → from source perspective, Zin = R + 1/(jωC)|ω=0 = ∞
        // For transfer function analysis (DC), C is open → gain = 1, Zin = ∞, Zout = R
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let (plan, devices) = try CircuitFactory.compile(netlist)

        let tfAnalysis = TransferFunctionAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await tfAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // DC gain: capacitor open → all voltage appears at output → gain = 1.0
        #expect(abs(result.gain - 1.0) < 0.01,
                "RC LPF DC gain should be 1.0, got \(result.gain)")

        // Output impedance: looking into output with source zeroed, see R in series with open C
        // Zout = R = 1000Ω (source zeroed → short, see R from output)
        #expect(abs(result.outputImpedance - 1000.0) < 10.0,
                "RC LPF Zout should be R=1kΩ, got \(result.outputImpedance)")

        // DC operating point: V(out) = 1.0V (no current through R with C open)
        let vOut = result.dcOperatingPoint.voltage(at: out)
        #expect(abs(vOut - 1.0) < 1e-6,
                "DC operating point V(out) should be 1.0V, got \(vOut)")
    }

    // MARK: - D3: VCVS Inverting Amplifier Transfer Function

    @Test("D3: VCVS inverting amplifier transfer function")
    func vcvsInvertingAmplifier() async throws {
        // E1(gain=1e5) inverting amplifier: Vin → Ri(1kΩ) → inv_node, Rf(10kΩ) → inv_node → out
        // V1(1V) → Ri(1kΩ) → inv → Rf(10kΩ) → out, E1(1e5) from (0,inv) to (out,0)
        // Closed loop gain ≈ -Rf/Ri = -10
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("inv")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // E1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "Ri", typeName: "resistor", nodes: ["in", "inv"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "Rf", typeName: "resistor", nodes: ["inv", "out"],
                                parameters: ["r": .real(10000)])
        // E1 senses (GND - inv) and outputs to (out, GND)
        // For inverting: non-inv input at GND, inv input at "inv"
        try netlist.addInstance(name: "E1", typeName: "vcvs", nodes: ["out", "0", "0", "inv"],
                                parameters: ["e": .real(1e5)])

        let (plan, devices) = try CircuitFactory.compile(netlist)

        let tfAnalysis = TransferFunctionAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await tfAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Closed-loop gain ≈ -Rf/Ri = -10
        #expect(abs(result.gain - (-10.0)) < 0.1,
                "Inverting amp gain should be ~-10, got \(result.gain)")

        // DC operating point: V(out) ≈ -10V
        let vOut = result.dcOperatingPoint.voltage(at: out)
        #expect(abs(vOut - (-10.0)) < 0.1,
                "DC V(out) should be ~-10V, got \(vOut)")
    }

    // MARK: - D5: Non-Inverting Amplifier Transfer Function

    @Test("D5: VCVS non-inverting amplifier transfer function")
    func vcvsNonInvertingAmplifier() async throws {
        // Non-inverting: V1 → non-inv input of op-amp, feedback from out through R1 to inv,
        // R2 from inv to GND
        // Gain = 1 + Rf/R1 = 1 + 9k/1k = 10
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("inv")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // E1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(1.0)])
        // Feedback resistor: out → inv
        try netlist.addInstance(name: "Rf", typeName: "resistor", nodes: ["out", "inv"],
                                parameters: ["r": .real(9000)])
        // Ground resistor: inv → GND
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["inv", "0"],
                                parameters: ["r": .real(1000)])
        // E1 senses (in - inv) and outputs to (out, GND)
        try netlist.addInstance(name: "E1", typeName: "vcvs", nodes: ["out", "0", "in", "inv"],
                                parameters: ["e": .real(1e5)])

        let (plan, devices) = try CircuitFactory.compile(netlist)

        let tfAnalysis = TransferFunctionAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await tfAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // Non-inverting gain = 1 + Rf/R1 = 10
        #expect(abs(result.gain - 10.0) < 0.1,
                "Non-inverting amp gain should be ~10, got \(result.gain)")

        // DC operating point: V(out) = 10V
        let vOut = result.dcOperatingPoint.voltage(at: out)
        #expect(abs(vOut - 10.0) < 0.1,
                "DC V(out) should be ~10V, got \(vOut)")
    }
}
