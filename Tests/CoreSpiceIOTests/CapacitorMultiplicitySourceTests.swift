import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO
import Foundation
import Testing

@Suite("Capacitor source multiplicity", .timeLimit(.minutes(1)))
struct CapacitorMultiplicitySourceTests {
    @Test func rootSourceMultiplicityReachesAC() async throws {
        let ir = try await IOTestFrontend.parseAndLower("""
        parallel ideal capacitors
        I1 0 out dc .001 ac 1
        R1 out 0 1k
        C1 out 0 1n m=2
        .end
        """)
        let plan = try StandardCompiler().compile(ir: ir)
        let registry = DeviceRegistry.standard(), structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension, branchNames: plan.ir.branchNames,
            stampIndexResolver: { structure.index(row: $0, col: $1) })
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            let descriptor = try #require(registry.descriptor(for: instance.typeName))
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        let capacitor = try #require(ir.instances.first { $0.typeName == "capacitor" })
        let node = try #require(capacitor.nodes.first)
        let ac = try await ACAnalysis(sweep: .single(1000)).run(plan: plan, devices: devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let v = try ac.voltage(at: node, frequencyIndex: 0)
        let susceptance = 2 * Double.pi * 1000 * 2e-9
        let denominator = 1e-6 + susceptance * susceptance
        #expect(abs(v.real - 0.001 / denominator) < 1e-5)
        #expect(abs(v.imag + susceptance / denominator) < 1e-5)
    }
}
