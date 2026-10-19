import Testing
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
@testable import CoreSpiceAnalysis

@Suite("Transient endpoint clock grid", .timeLimit(.minutes(1)))
struct TransientEndpointGridTests {
    @Test func terminalApproachAvoidsAccumulatedClockRemainder() async throws {
        let step = 1e-10
        let endpoint = 1e-8
        let minimum = 1e-18
        var accumulated = 0.0
        for _ in 0..<100 { accumulated += step }
        #expect(endpoint - accumulated > 0)
        #expect(endpoint - accumulated < minimum)

        var netlist = Netlist()
        let output = netlist.node("out")
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(1)])
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["0", "out"],
            parameters: ["i": .real(1)])
        let plan = try StandardCompiler().compile(ir: netlist.build())
        let circuit = try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances)
        let result = try await TransientAnalysis(config: .init(stopTime: endpoint,
            executionLimits: .validationFixture, maxTimeStep: step, initialTimeStep: step,
            minTimeStep: minimum)).run(plan: plan, devices: circuit.devices, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
        #expect(result.timePoints.first == 0)
        #expect(result.timePoints.last == endpoint)
        #expect(result.acceptedSteps.allSatisfy { $0.timeStep >= minimum && $0.timeStep <= step })
        #expect(result.acceptedSteps.suffix(2).allSatisfy { $0.timeStep > step / 4 && $0.timeStep < step })
        for point in result.timePoints.indices {
            #expect(abs(try result.voltage(at: output, timeIndex: point) - 1) < 1e-12)
            if point > 0 { #expect(result.timePoints[point] > result.timePoints[point - 1]) }
        }
    }
}
