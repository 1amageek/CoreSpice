import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceIO
import Foundation
import Testing

@Suite("Capacitor public source admission", .timeLimit(.minutes(1)))
struct CapacitorSourceAdmissionTests {
    @Test func unusedDeclarationDoesNotExecuteItsCoefficientsAndIdealPathStillSolves() async throws {
        let ir = try await SPICEIO.parseAndLower("""
        unused capacitor model and ideal execution
        .param cv=1n
        I1 0 out dc .001 ac 1
        R1 out 0 1k
        C1 out 0 c=cv*2
        .model unused C cox={missing} capsw={also_missing} tc1=.001 tnom=25
        .end
        """)
        let cap = try #require(ir.instances.first { $0.name.lowercased() == "c1" })
        #expect(cap.model == nil)
        guard case .real(let capacitance) = cap.parameters["c"] else {
            Issue.record("Expected complete scalar capacitance expression")
            return
        }
        #expect(capacitance == 2e-9)
        let plan = try StandardCompiler().compile(ir: ir)
        let registry = DeviceRegistry.standard()
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension, branchNames: plan.ir.branchNames,
            stampIndexResolver: { structure.index(row: $0, col: $1) })
        var devices: [any BoundDevice] = []
        for instance in ir.instances {
            let descriptor = try #require(registry.descriptor(for: instance.typeName))
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        let node = try #require(cap.nodes.first)
        let dc = try await DCAnalysis().run(plan: plan, devices: devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        #expect(abs(try dc.voltage(at: node) - 1) < 1e-8)
        let ac = try await ACAnalysis(sweep: .single(1000)).run(plan: plan, devices: devices,
            solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let result = try ac.voltage(at: node, frequencyIndex: 0)
        let factor = 2 * Double.pi * 1000 * 1000 * 2e-9
        #expect(abs(result.real - 1000 / (1 + factor * factor)) < 1e-5)
        #expect(abs(result.imag + 1000 * factor / (1 + factor * factor)) < 1e-5)
    }

    @Test func coverageNeverPromotesModelDeclarationOrExplicitModelInstance() async throws {
        let parsed = try await SPICEIO.parse("""
        capacitor model coverage
        Cbare a 0 cm
        Cexplicit b 0 1p cm
        .model cm C cox=1n
        .end
        """).get()
        let report = SPICEDeckCoverageReport.generate(from: parsed)
        for name in ["model:cm", "component:cbare", "component:cexplicit"] {
            let item = try #require(report.items.first { $0.name == name })
            #expect(item.status == .blocked)
            #expect(item.message.contains("not implemented"))
        }
        #expect(report.hasBlockedItems)
    }

    @Test func coverageUsesGlobalAndSubcircuitParameterPresenceBeforeModelNames() async throws {
        let parsed = try await SPICEIO.parse("""
        capacitor parameter coverage
        .param cv=1n
        .model cv C cap=9n
        Croot a 0 cv
        .subckt cell a params: local=2n
        Cparent a 0 cv
        Clocal a 0 local
        .model local C cap=7n
        .ends
        X1 out cell
        .end
        """).get()
        let report = SPICEDeckCoverageReport.generate(from: parsed)
        for name in ["component:croot", "subckt:cell/component:cparent", "subckt:cell/component:clocal"] {
            #expect(try #require(report.items.first { $0.name == name }).status == .supported)
        }
        #expect(try #require(report.items.first { $0.name == "model:cv" }).status == .blocked)
    }
}
