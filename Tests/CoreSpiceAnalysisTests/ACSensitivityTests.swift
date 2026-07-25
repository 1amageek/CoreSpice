import Testing
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("AC Sensitivity Tests")
struct ACSensitivityTests {
    @Test
    func rcLowPassResistanceSensitivityMatchesAnalyticDerivative() async throws {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let output = netlist.node("out")
        let _ = netlist.branch(name: "V1")
        try netlist.addInstance(
            name: "V1",
            typeName: "vsource",
            nodes: ["in", "0"],
            parameters: ["v": .real(0.0), "ac": .real(1.0)]
        )
        try netlist.addInstance(
            name: "R1",
            typeName: "resistor",
            nodes: ["in", "out"],
            parameters: ["r": .real(1_000.0)]
        )
        try netlist.addInstance(
            name: "C1",
            typeName: "capacitor",
            nodes: ["out", "0"],
            parameters: ["c": .real(1e-6)]
        )
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let frequency = 100.0
        let result = try await ACSensitivityAnalysis(
            outputPositiveNode: output,
            sweep: .single(frequency)
        ).run(
            plan: plan,
            devices: devices,
            solver: SparseLUSolver(),
            observer: nil,
            cancellation: CancellationToken()
        )

        let resistance = try #require(result.sensitivities.first {
            $0.deviceName == "R1" && $0.parameterName == "r"
        })
        let observed = try #require(resistance.sensitivities.first)
        let omegaC = 2.0 * Double.pi * frequency * 1e-6
        let denominator = ComplexPair(real: 1.0, imag: omegaC * 1_000.0)
        let expected = ComplexPair(real: 0.0, imag: -omegaC)
            / (denominator * denominator)

        #expect(abs(observed.real - expected.real) < max(abs(expected.real) * 1e-3, 1e-10))
        #expect(abs(observed.imag - expected.imag) < max(abs(expected.imag) * 1e-3, 1e-10))
        #expect(result.sensitivities.contains {
            $0.deviceName == "V1"
                && $0.parameterName == "v"
                && $0.nominalValue == 0.0
        })
    }

    @Test
    func resultRejectsMismatchedFrequencyData() {
        #expect(throws: AnalysisError.self) {
            _ = try ACSensitivityResult(
                outputVariable: "V(out)",
                frequencies: [1.0],
                baselineValues: [],
                sensitivities: []
            )
        }
    }
}
