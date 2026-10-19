import Testing
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Exact transfer port impedance", .timeLimit(.minutes(1)))
struct PortImpedanceTests {
    @Test func finiteTinyInputCurrentHasFiniteHugeImpedance() async throws {
        let result = try await transfer(resistance: 1e31)
        guard case .finite(let impedance) = result.inputPortImpedance else {
            Issue.record("A nonzero current cannot denote an open port")
            return
        }
        #expect(abs(impedance / 1e31 - 1) < 1e-12)
        #expect(result.inputImpedance == impedance)
        #expect(result.gain == 1)
        #expect(result.outputPortImpedance == .finite(0))
    }

    @Test func exactlyUnloadedVoltageSourceHasOpenInput() async throws {
        let result = try await transfer(resistance: nil)
        #expect(result.inputPortImpedance == .openCircuit)
        #expect(result.inputImpedance == .infinity)
        #expect(result.gain == 1)
        #expect(result.outputPortImpedance == .finite(0))
    }

    @Test func nonzeroReciprocalOverflowCannotBecomeOpenCircuit() throws {
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try PortImpedance(reciprocalOf: Double.leastNonzeroMagnitude)
        }
        #expect(try PortImpedance(reciprocalOf: 0) == .openCircuit)
        #expect(try PortImpedance(reciprocalOf: -0.25) == .finite(-4))
    }

    @Test func resultRejectsInvalidFinitePayloadAndNegativeInfinity() throws {
        let op = try DCResult(variables: [], variableMap: [:], iterations: 0)
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(throws: AnalysisResultValidationError.self) {
                _ = try TransferFunctionResult(gain: 1, inputPortImpedance: .finite(invalid),
                    outputPortImpedance: .finite(0), dcOperatingPoint: op, variableMap: [:])
            }
            #expect(throws: AnalysisResultValidationError.self) {
                _ = try TransferFunctionResult(gain: 1, inputPortImpedance: .openCircuit,
                    outputPortImpedance: .finite(invalid), dcOperatingPoint: op, variableMap: [:])
            }
        }
        #expect(throws: AnalysisResultValidationError.self) {
            _ = try TransferFunctionResult(gain: 1, inputImpedance: -.infinity,
                outputImpedance: 0, dcOperatingPoint: op, variableMap: [:])
        }
        let active = try TransferFunctionResult(gain: 1, inputPortImpedance: .finite(-4),
            outputPortImpedance: .finite(-2), dcOperatingPoint: op, variableMap: [:])
        #expect(active.inputImpedance == -4)
        #expect(active.outputImpedance == -2)
    }

    private func transfer(resistance: Double?) async throws -> TransferFunctionResult {
        var netlist = Netlist()
        let output = netlist.node("out")
        let branch = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["out", "0"],
            parameters: ["v": .real(1)], ownedBranches: [branch])
        if let resistance {
            try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                parameters: ["r": .real(resistance)])
        }
        let plan = try StandardCompiler().compile(ir: netlist.build())
        let circuit = try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances)
        return try await TransferFunctionAnalysis(outputNode: output, inputSourceName: "V1")
            .run(plan: plan, devices: circuit.devices, solver: SparseLUSolver(), observer: nil,
                cancellation: CancellationToken())
    }
}
