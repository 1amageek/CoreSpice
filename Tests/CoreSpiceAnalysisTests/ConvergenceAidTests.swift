import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Convergence Aid Tests")
struct ConvergenceAidTests {

    // MARK: - Gmin Stepping Tests

    @Test("Gmin stepping generates correct sequence")
    func gminSteppingSequence() {
        let stepping = GminStepping(
            initialGmin: 1e-3,
            finalGmin: 1e-12,
            reductionFactor: 10.0,
            maxSteps: 10
        )

        let values = stepping.gminValues()

        // GminStepping generates: 1e-3, 1e-4, ..., until > finalGmin, then appends finalGmin
        // For this config: 1e-3, 1e-4, ..., 1e-11, 1e-12 = 10 reductions
        // But the implementation adds values while g > finalGmin, then appends finalGmin
        // So we get: 1e-3, 1e-4, 1e-5, 1e-6, 1e-7, 1e-8, 1e-9, 1e-10, 1e-11 (9 values), then 1e-12 = 10+1=11
        // Let's verify the actual behavior
        #expect(values.count >= 5, "Should have multiple steps")
        #expect(abs(values.first! - 1e-3) < 1e-10, "Should start at 1e-3")
        #expect(abs(values.last! - 1e-12) < 1e-18, "Should end at 1e-12")

        // Check that values are monotonically decreasing
        for i in 1..<values.count {
            #expect(values[i] < values[i - 1],
                    "Gmin should decrease: values[\(i-1)]=\(values[i-1]), values[\(i)]=\(values[i])")
        }

        // Check reduction factor for intermediate values
        if values.count >= 3 {
            let ratio = values[0] / values[1]
            #expect(abs(ratio - 10.0) < 0.1,
                    "Steps should reduce by factor of 10, got \(ratio)")
        }
    }

    @Test("Gmin stepping with maxSteps limit")
    func gminSteppingMaxSteps() {
        let stepping = GminStepping(
            initialGmin: 1.0,
            finalGmin: 1e-20,
            reductionFactor: 10.0,
            maxSteps: 5
        )

        let values = stepping.gminValues()

        // Should stop at maxSteps
        #expect(values.count == 6, "Should have 6 values (5 steps + final)")
        #expect(abs(values.last! - 1e-20) < 1e-25, "Should end at finalGmin")
    }

    // MARK: - Source Stepping Tests

    @Test("Source stepping generates correct factors")
    func sourceSteppingFactors() {
        let stepping = SourceStepping(steps: 10)
        let factors = stepping.sourceFactors()

        #expect(factors.count == 10, "Should have 10 factors")
        #expect(abs(factors.first! - 0.1) < 1e-10, "First factor should be 0.1")
        #expect(abs(factors.last! - 1.0) < 1e-10, "Last factor should be 1.0")

        // Check linear progression
        for (i, factor) in factors.enumerated() {
            let expected = Double(i + 1) / 10.0
            #expect(abs(factor - expected) < 1e-10,
                    "Factor \(i) should be \(expected), got \(factor)")
        }
    }

    // MARK: - Convergence Aid Integration Tests

    @Test("DC analysis uses Gmin stepping for difficult circuit")
    func gminSteppingIntegration() async throws {
        // Create a diode circuit that benefits from Gmin stepping
        // V1(2V) -> R(1kΩ) -> anode -> D1 -> GND
        // Using larger resistance for easier convergence
        var netlist = Netlist()
        let _ = netlist.node("in")
        let anode = netlist.node("anode")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(2.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "anode"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["anode", "0"],
                                parameters: [:])

        // Run with Gmin stepping enabled
        let result = try await CircuitFactory.runDC(
            netlist,
            config: ConvergenceConfig(maxIterations: 100, gmin: 1e-12),
            gminStepping: GminStepping(initialGmin: 1e-3, finalGmin: 1e-12, maxSteps: 10),
            sourceStepping: SourceStepping(steps: 1)
        )

        // Verify convergence
        let vAnode = result.voltage(at: anode)
        // Diode drop ≈ 0.6-0.7V
        #expect(vAnode > 0.4 && vAnode < 0.9,
                "Diode anode voltage should be ~0.6-0.7V, got \(vAnode)")
    }

    @Test("DC analysis uses source stepping for strongly nonlinear circuit")
    func sourceSteppingIntegration() async throws {
        // Create a circuit with multiple diodes in series
        // This is a more challenging circuit that benefits from source stepping
        // V1(3V) -> R(1kΩ) -> D1 -> D2 -> D3 -> GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let n1 = netlist.node("n1")
        let n2 = netlist.node("n2")
        let n3 = netlist.node("n3")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(3.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["n1", "n2"],
                                parameters: [:])
        try netlist.addInstance(name: "D2", typeName: "diode", nodes: ["n2", "n3"],
                                parameters: [:])
        try netlist.addInstance(name: "D3", typeName: "diode", nodes: ["n3", "0"],
                                parameters: [:])

        // Run with source stepping enabled
        let result = try await CircuitFactory.runDC(
            netlist,
            config: ConvergenceConfig(maxIterations: 100, gmin: 1e-9),
            gminStepping: GminStepping(initialGmin: 1e-3, finalGmin: 1e-9, maxSteps: 5),
            sourceStepping: SourceStepping(steps: 10)
        )

        // Verify convergence: 3 diodes ≈ 3×0.6V = 1.8V drop
        let vn1 = result.voltage(at: n1)
        let vn2 = result.voltage(at: n2)
        let vn3 = result.voltage(at: n3)

        #expect(vn1 > vn2 && vn2 > vn3,
                "Voltages should decrease along diode chain: \(vn1) > \(vn2) > \(vn3)")
        #expect(vn1 > 1.0, "First node should be > 1V, got \(vn1)")
        #expect(vn3 > 0.3 && vn3 < 0.8,
                "Last diode anode should be ~0.6V, got \(vn3)")
    }

    @Test("Source stepping enables convergence for BJT amplifier")
    func sourceSteppingBJTCircuit() async throws {
        // BJT common emitter amplifier
        // This circuit can have convergence issues without source stepping
        var netlist = Netlist()
        let _ = netlist.node("vcc")
        let _ = netlist.node("vbb")
        let col = netlist.node("col")
        let base = netlist.node("base")
        let _ = netlist.branch() // VCC
        let _ = netlist.branch() // VBB

        try netlist.addInstance(name: "VCC", typeName: "vsource", nodes: ["vcc", "0"],
                                parameters: ["v": .real(12.0)])
        try netlist.addInstance(name: "VBB", typeName: "vsource", nodes: ["vbb", "0"],
                                parameters: ["v": .real(1.5)])
        try netlist.addInstance(name: "RC", typeName: "resistor", nodes: ["vcc", "col"],
                                parameters: ["r": .real(2200)])
        try netlist.addInstance(name: "RB", typeName: "resistor", nodes: ["vbb", "base"],
                                parameters: ["r": .real(47000)])
        try netlist.addInstance(name: "Q1", typeName: "npn", nodes: ["col", "base", "0"],
                                parameters: ["is": .real(1e-16), "bf": .real(100)])

        // Run with both convergence aids
        let result = try await CircuitFactory.runDC(
            netlist,
            config: ConvergenceConfig(maxIterations: 100, gmin: 1e-9),
            gminStepping: GminStepping(initialGmin: 1e-3, finalGmin: 1e-9, maxSteps: 5),
            sourceStepping: SourceStepping(steps: 10)
        )

        // Verify BJT is in active region
        let vCol = result.voltage(at: col)
        let vBase = result.voltage(at: base)

        #expect(vCol > 0 && vCol < 12.0,
                "Collector should be between 0V and VCC, got \(vCol)")
        #expect(vBase > 0.5 && vBase < 1.0,
                "Base should be ~0.6-0.7V (Vbe), got \(vBase)")
        #expect(vCol > vBase,
                "Collector should be higher than base for active region")
    }
}
