import Testing
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Compensated DC sensitivity", .timeLimit(.minutes(1)))
struct CompensatedDCSensitivityTests {
    @Test func currentSensitivityRetainsVoltageDifferenceEntirelyInLowComponents() async throws {
        var netlist = Netlist()
        _ = netlist.node("in")
        let output = netlist.node("out")
        _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(0.5)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(1e-6)])
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["out", "0"],
            parameters: ["i": .real(1e-11)])
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let result = try await SensitivityAnalysis(outputNode: output,
            dcConfig: .init(abstol: 1e-12, reltol: 0, gmin: 0)).run(
                plan: plan, devices: devices, solver: SparseLUSolver(), observer: nil,
                cancellation: .init())

        let baseline = try result.dcOperatingPoint.checkedCompensatedVoltage(at: output)
        #expect(baseline.high == 0.5 && baseline.low != 0)
        let current = try #require(result.sensitivities.first {
            $0.deviceName == "I1" && $0.parameterName == "i"
        })
        // The admitted prepared conductance is exactly 1e6 S, so dVout/dI = -1e-6 V/A.
        #expect(abs(current.sensitivity + 1e-6) < 1e-15)
        let normalized = try #require(current.normalizedSensitivity)
        #expect(abs(normalized + 2e-17) < 2e-26)
    }
}
