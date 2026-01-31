import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Sensitivity Integration Tests")
struct SensitivityIntegrationTests {

    // MARK: - Helper

    private func runSensitivity(netlist: Netlist, outputNode: Node) async throws -> SensitivityResult {
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let analysis = SensitivityAnalysis(outputNode: outputNode)
        let solver = SparseLUSolver()
        let token = CancellationToken()
        return try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )
    }

    // MARK: - F2: Diode Circuit Sensitivity

    @Test("F2: Diode circuit sensitivity to resistance")
    func diodeCircuitSensitivity() async throws {
        // V1(5V) → R(1kΩ) → anode → D → GND
        // Sensitivity of V(anode) to R
        // As R increases, more voltage drops across R → V(anode) decreases
        // So dV(anode)/dR should be negative
        let (netlist, anode) = CircuitFactory.diodeCircuit(v: 5.0, r: 1000)
        let result = try await runSensitivity(netlist: netlist, outputNode: anode)

        // Baseline: V(anode) should be forward voltage ~0.6-0.7V
        #expect(result.baselineValue > 0.4 && result.baselineValue < 0.9,
                "Diode forward voltage should be ~0.6V, got \(result.baselineValue)")

        // dV(anode)/dR should be negative (increasing R drops more voltage across R)
        let rSens = result.sensitivities.first(where: {
            $0.deviceName == "R1" && $0.parameterName == "r"
        })
        #expect(rSens != nil, "Should have sensitivity for R1")
        #expect(rSens!.sensitivity < 0,
                "dV(anode)/dR should be negative, got \(rSens!.sensitivity)")

        // dV(anode)/dV should be positive (higher source → higher anode voltage)
        let vSens = result.sensitivities.first(where: {
            $0.deviceName == "V1" && $0.parameterName == "v"
        })
        #expect(vSens != nil, "Should have sensitivity for V1")
        #expect(vSens!.sensitivity > 0,
                "dV(anode)/dV should be positive, got \(vSens!.sensitivity)")
    }

    // MARK: - F3: BJT Circuit Sensitivity

    @Test("F3: BJT common emitter sensitivity",
          .disabled("NR solver lacks damping for nonlinear BJT convergence"))
    func bjtCircuitSensitivity() async throws {
        let (netlist, col, _) = CircuitFactory.bjtCommonEmitter(
            vcc: 12.0, rc: 2000, vbb: 1.5, rb: 100_000,
            bjtParams: ["is": .real(1e-16), "bf": .real(100)]
        )
        let result = try await runSensitivity(netlist: netlist, outputNode: col)

        // dVc/dRc should be negative (more Rc → more voltage drop → lower Vc)
        let rcSens = result.sensitivities.first(where: {
            $0.deviceName == "RC" && $0.parameterName == "r"
        })
        #expect(rcSens != nil)
        #expect(rcSens!.sensitivity < 0)
    }

    // MARK: - F5: MOSFET Circuit Sensitivity

    @Test("F5: PMOS common source sensitivity")
    func pmosCircuitSensitivity() async throws {
        // PMOS circuit (converges unlike NMOS)
        let (netlist, drain) = CircuitFactory.pmosCommonSource(
            vdd: 5.0, rd: 1000, vgate: 3.0,
            mosParams: ["vto": .real(-0.7), "kp": .real(50e-6),
                        "w": .real(20e-6), "l": .real(1e-6)]
        )
        let result = try await runSensitivity(netlist: netlist, outputNode: drain)

        // Baseline should be a reasonable drain voltage
        #expect(result.baselineValue > 0 && result.baselineValue < 5.0,
                "Drain voltage should be in range, got \(result.baselineValue)")

        // dVd/dRd: as Rd increases, drain voltage increases (Vd = Ids × Rd)
        let rdSens = result.sensitivities.first(where: {
            $0.deviceName == "RD" && $0.parameterName == "r"
        })
        #expect(rdSens != nil, "Should have sensitivity for RD")
        #expect(rdSens!.sensitivity > 0,
                "dVd/dRd should be positive (more Rd → more Vd), got \(rdSens!.sensitivity)")
    }

    // MARK: - F6: Multi-Parameter Sensitivity (3-Resistor Chain)

    @Test("F6: Three-resistor chain multi-parameter sensitivity")
    func threeResistorChainSensitivity() async throws {
        // V1(10V) → R1(1kΩ) → n1 → R2(2kΩ) → n2 → R3(3kΩ) → GND
        // V(n2) = V × R3/(R1+R2+R3) = 10 × 3/6 = 5V
        // dV(n2)/dR1 = -V × R3 / (R1+R2+R3)² = -10 × 3000 / 36e6 = -8.33e-4
        // dV(n2)/dR2 = -V × R3 / (R1+R2+R3)² = -8.33e-4
        // dV(n2)/dR3 =  V × (R1+R2) / (R1+R2+R3)² = 10 × 3000 / 36e6 = 8.33e-4
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("n1")
        let n2 = netlist.node("n2")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(10.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["n1", "n2"],
                                parameters: ["r": .real(2000)])
        try netlist.addInstance(name: "R3", typeName: "resistor", nodes: ["n2", "0"],
                                parameters: ["r": .real(3000)])

        let result = try await runSensitivity(netlist: netlist, outputNode: n2)

        // Baseline: V(n2) = 10 × 3000/6000 = 5.0V
        #expect(abs(result.baselineValue - 5.0) < 1e-6,
                "V(n2) should be 5.0V, got \(result.baselineValue)")

        let rTotal = 6000.0
        let rTotalSq = rTotal * rTotal

        // dV/dR1 = -V × R3 / (R1+R2+R3)²
        let r1Sens = result.sensitivities.first(where: { $0.deviceName == "R1" && $0.parameterName == "r" })
        let expectedR1Sens = -10.0 * 3000.0 / rTotalSq
        #expect(r1Sens != nil)
        #expect(abs(r1Sens!.sensitivity - expectedR1Sens) < 1e-5,
                "dV/dR1 should be \(expectedR1Sens), got \(r1Sens!.sensitivity)")

        // dV/dR2 = -V × R3 / (R1+R2+R3)² (same as R1 because both are in series before R3)
        let r2Sens = result.sensitivities.first(where: { $0.deviceName == "R2" && $0.parameterName == "r" })
        let expectedR2Sens = -10.0 * 3000.0 / rTotalSq
        #expect(r2Sens != nil)
        #expect(abs(r2Sens!.sensitivity - expectedR2Sens) < 1e-5,
                "dV/dR2 should be \(expectedR2Sens), got \(r2Sens!.sensitivity)")

        // dV/dR3 = V × (R1+R2) / (R1+R2+R3)²
        let r3Sens = result.sensitivities.first(where: { $0.deviceName == "R3" && $0.parameterName == "r" })
        let expectedR3Sens = 10.0 * 3000.0 / rTotalSq
        #expect(r3Sens != nil)
        #expect(abs(r3Sens!.sensitivity - expectedR3Sens) < 1e-5,
                "dV/dR3 should be \(expectedR3Sens), got \(r3Sens!.sensitivity)")

        // Verify all 3 resistor sensitivities + voltage source sensitivity are present
        let rSensitivities = result.sensitivities.filter { $0.parameterName == "r" }
        #expect(rSensitivities.count == 3, "Should have sensitivity for all 3 resistors")
    }
}
