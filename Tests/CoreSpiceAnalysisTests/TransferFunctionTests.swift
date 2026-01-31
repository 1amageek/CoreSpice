import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Transfer Function Analysis Tests")
struct TransferFunctionTests {

    // MARK: - Helper

    private func buildDivider(
        voltage: Double,
        r1: Double,
        r2: Double
    ) throws -> (plan: ExecutionPlan, devices: [any BoundDevice], outNode: Node) {
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()

        try netlist.addInstance(
            name: "V1", typeName: "vsource", nodes: ["in", "0"],
            parameters: ["v": .real(voltage)]
        )
        try netlist.addInstance(
            name: "R1", typeName: "resistor", nodes: ["in", "out"],
            parameters: ["r": .real(r1)]
        )
        try netlist.addInstance(
            name: "R2", typeName: "resistor", nodes: ["out", "0"],
            parameters: ["r": .real(r2)]
        )

        let ir = try netlist.build()
        let compiler = StandardCompiler()
        let plan = try compiler.compile(ir: ir)

        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            guard let desc = registry.descriptor(for: instance.typeName) else { continue }
            let bound = try desc.bind(instance: instance, context: &context)
            devices.append(bound)
        }

        return (plan, devices, out)
    }

    /// Resistive voltage divider: V1(5V) -> R1(1k) -> out -> R2(1k) -> GND
    /// gain = R2 / (R1 + R2) = 0.5
    /// Zin  = R1 + R2 = 2000
    /// Zout = R1 || R2 = 500
    @Test func resistiveDividerTransferFunction() async throws {
        let (plan, devices, out) = try buildDivider(voltage: 5.0, r1: 1000, r2: 1000)

        let tfAnalysis = TransferFunctionAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await tfAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        #expect(abs(result.gain - 0.5) < 1e-6)
        #expect(abs(result.inputImpedance - 2000.0) < 1.0)
        #expect(abs(result.outputImpedance - 500.0) < 1.0)
    }

    /// Asymmetric divider: V1(10V) -> R1(1k) -> out -> R2(3k) -> GND
    /// gain = 3000 / 4000 = 0.75
    /// Zin  = 4000
    /// Zout = 1000 * 3000 / 4000 = 750
    @Test func asymmetricDividerTransferFunction() async throws {
        let (plan, devices, out) = try buildDivider(voltage: 10.0, r1: 1000, r2: 3000)

        let tfAnalysis = TransferFunctionAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await tfAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        #expect(abs(result.gain - 0.75) < 1e-6)
        #expect(abs(result.inputImpedance - 4000.0) < 1.0)
        let expectedZout = 1000.0 * 3000.0 / 4000.0
        #expect(abs(result.outputImpedance - expectedZout) < 1.0)
    }

    /// DC operating point is included in result.
    @Test func transferFunctionIncludesDCOperatingPoint() async throws {
        let (plan, devices, out) = try buildDivider(voltage: 5.0, r1: 1000, r2: 1000)

        let tfAnalysis = TransferFunctionAnalysis(
            outputNode: out,
            inputSourceName: "V1"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await tfAnalysis.run(
            plan: plan,
            devices: devices,
            solver: solver,
            observer: nil,
            cancellation: token
        )

        // DC operating point should show V(out) = 2.5V
        let vOut = result.dcOperatingPoint.voltage(at: out)
        #expect(abs(vOut - 2.5) < 1e-6)
    }

    /// Invalid input source name should throw.
    @Test func invalidInputSourceThrows() async throws {
        let (plan, devices, out) = try buildDivider(voltage: 5.0, r1: 1000, r2: 1000)

        let tfAnalysis = TransferFunctionAnalysis(
            outputNode: out,
            inputSourceName: "NONEXISTENT"
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()

        await #expect(throws: AnalysisError.self) {
            try await tfAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: nil,
                cancellation: token
            )
        }
    }
}
