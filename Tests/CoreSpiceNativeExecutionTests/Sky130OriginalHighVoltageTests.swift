import CoreSpice
import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceMOSResolution
import CoreSpiceParserSPICE
import CoreSpiceMOSContracts
import Foundation
import Testing

@Suite("Original Sky130 high-voltage admission", .serialized, .timeLimit(.minutes(2)))
struct Sky130OriginalHighVoltageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"] != nil,
                   "Requires explicit unchanged original Sky130 source root"), arguments: ["nfet", "pfet"])
    func originalComposedHighVoltageAdmission(family: String) async throws {
        let root = try #require(ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"])
        let corner = "sky130_fd_pr__\(family)_20v0__tt_discrete.corner.spice"
        let files: [String]
        let routes: [SPICESourceCatalogRoute]
        if family == "nfet" {
            files = [
                "../../../libs.tech/ngspice/parasitics/sky130_fd_pr__model__parasitic__diode_ps2dn__extended_drain.model.spice",
                "../../../libs.tech/ngspice/parasitics/sky130_fd_pr__model__parasitic__diode_pw2dn__extended_drain.model.spice",
                "sky130_fd_pr__diode_pw2nd_05v5__extended_drain.model.spice",
                "sky130_fd_pr__nfet_20v0__subcircuit.pm3.spice",
                "sky130_fd_pr__nfet_20v0__tt_discrete.corner.spice",
                "sky130_fd_pr__nfet_20v0_iso__subcircuit.pm3.spice",
                "sky130_fd_pr__nfet_20v0_reverse_iso__subcircuit.pm3.spice",
                "sky130_fd_pr__nfet_20v0_zvt__parasitic__diode_ps2dn__extended_drain.model.spice",
                "sky130_fd_pr__nfet_20v0_zvt__subcircuit.pm3.spice",
                "sky130_fd_pr__nfet_20v0_zvt__tt_discrete.corner.spice"]
            routes = [
                .init(parentKey: "sky130_fd_pr__nfet_20v0__tt_discrete.corner.spice", childKey: "sky130_fd_pr__nfet_20v0__subcircuit.pm3.spice", literalRoute: "sky130_fd_pr__nfet_20v0__subcircuit.pm3.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0__subcircuit.pm3.spice", childKey: "../../../libs.tech/ngspice/parasitics/sky130_fd_pr__model__parasitic__diode_pw2dn__extended_drain.model.spice", literalRoute: "../../../libs.tech/ngspice/parasitics/sky130_fd_pr__model__parasitic__diode_pw2dn__extended_drain.model.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0__subcircuit.pm3.spice", childKey: "sky130_fd_pr__diode_pw2nd_05v5__extended_drain.model.spice", literalRoute: "sky130_fd_pr__diode_pw2nd_05v5__extended_drain.model.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0__tt_discrete.corner.spice", childKey: "sky130_fd_pr__nfet_20v0_iso__subcircuit.pm3.spice", literalRoute: "sky130_fd_pr__nfet_20v0_iso__subcircuit.pm3.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0_iso__subcircuit.pm3.spice", childKey: "../../../libs.tech/ngspice/parasitics/sky130_fd_pr__model__parasitic__diode_ps2dn__extended_drain.model.spice", literalRoute: "../../../libs.tech/ngspice/parasitics/sky130_fd_pr__model__parasitic__diode_ps2dn__extended_drain.model.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0_iso__subcircuit.pm3.spice", childKey: "sky130_fd_pr__nfet_20v0_reverse_iso__subcircuit.pm3.spice", literalRoute: "sky130_fd_pr__nfet_20v0_reverse_iso__subcircuit.pm3.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0__tt_discrete.corner.spice", childKey: "sky130_fd_pr__nfet_20v0_zvt__tt_discrete.corner.spice", literalRoute: "sky130_fd_pr__nfet_20v0_zvt__tt_discrete.corner.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0_zvt__tt_discrete.corner.spice", childKey: "sky130_fd_pr__nfet_20v0_zvt__subcircuit.pm3.spice", literalRoute: "sky130_fd_pr__nfet_20v0_zvt__subcircuit.pm3.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__nfet_20v0_zvt__subcircuit.pm3.spice", childKey: "sky130_fd_pr__nfet_20v0_zvt__parasitic__diode_ps2dn__extended_drain.model.spice", literalRoute: "sky130_fd_pr__nfet_20v0_zvt__parasitic__diode_ps2dn__extended_drain.model.spice", kind: .include)]
        } else {
            files = [
                "sky130_fd_pr__pfet_20v0__parasitic__diode_pw2dn.model.spice",
                "sky130_fd_pr__pfet_20v0__subcircuit.pm3.spice",
                "sky130_fd_pr__pfet_20v0__tt_discrete.corner.spice"]
            routes = [
                .init(parentKey: "sky130_fd_pr__pfet_20v0__tt_discrete.corner.spice", childKey: "sky130_fd_pr__pfet_20v0__subcircuit.pm3.spice", literalRoute: "sky130_fd_pr__pfet_20v0__subcircuit.pm3.spice", kind: .include),
                .init(parentKey: "sky130_fd_pr__pfet_20v0__subcircuit.pm3.spice", childKey: "sky130_fd_pr__pfet_20v0__parasitic__diode_pw2dn.model.spice", literalRoute: "sky130_fd_pr__pfet_20v0__parasitic__diode_pw2dn.model.spice", kind: .include)]
        }
        let invariant = "../../../libs.tech/ngspice/parameters/invariant.spice"
        let lowVoltage = "sky130_fd_pr__nfet_01v8__tt.pm3.spice"
        let entries = family == "nfet" ? [invariant, lowVoltage, corner] : [invariant, corner]
        let allFiles = family == "nfet" ? [invariant, lowVoltage] + files : [invariant] + files
        let deck = "Original high-voltage admission\n.param mc_mm_switch=0 mc_pr_switch=0\n.option scale=1u bsim4stressiterations=64\n"
            + entries.map { ".include '\($0)'\n" }.joined()
            + "VD d 0 1.8\nVG g 0 1.2\nX1 d g 0 0 sky130_fd_pr__\(family)_20v0\n.op\n.end\n"
        do {
            let fixture = try await Sky130OriginalSourceFixture.prepare(root: root, files: allFiles,
                entries: entries, deck: deck, routes: routes)
            let result = try await DCAnalysis().run(circuit: fixture.prepareNative(capabilities: .dc),
                solver: SparseLUSolver(), observer: nil, cancellation: .init())
            Issue.record("Unadmitted composed high-voltage path published a numerical result: \(result.result.variables)")
        } catch let error as SPICESimulationPreparationError {
            guard case .resolution(.undefinedParameter, resourceCause: nil) = error else {
                Issue.record("Unexpected composed-wrapper refusal: \(error)"); return
            }
            // This is an input-binding refusal, not 4.5 numerical coverage or a 4.62 release refusal.
            print("original-high-voltage \(family) stage=scope-binding failure=\(error)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"] != nil,
                   "Requires explicit unchanged original Sky130 source root"))
    func original462DeclarationRefusesBeforeCoefficientEvaluation() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["MOS_ORIGINAL_SKY130_ROOT"])
        let path = URL(fileURLWithPath: root).appendingPathComponent("libs.ref/sky130_fd_pr/spice/sky130_fd_pr__pfet_20v0__subcircuit.pm3.spice").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let parsed = try await SPICEParser().parse(source: text, fileName: path).get()
        let limits = try MOSResolutionLimits(maximumRetainedBytes: 32_000_000, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 32, maximumSymbols: 2048, maximumScopes: 32, maximumInvocations: 32,
            maximumInvocationBindings: 512, maximumDeclarations: 128, maximumPrograms: 2048,
            maximumBindings: 512, maximumFunctions: 32, maximumFunctionDepth: 32,
            maximumExpressionNodes: 256, maximumExpressionDepth: 128, maximumCandidates: 128,
            maximumCacheEntries: 2048, maximumEvaluationSteps: 1_000_000)
        let snapshot = try NetlistLowering.compile(parsed, limits: limits).snapshot
        let declaration = try #require(snapshot.declarations.first { $0.originalName == "sky130_fd_pr__pfet_20v0__base.0" })
        #expect(declaration.version == "4.62" && declaration.level == 54)
        #expect(declaration.source.path == path)
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [
            try .init(id: 0, scope: .init(0), callerInvocationID: nil, actuals: [], limits: limits),
            try .init(id: 1, scope: declaration.scope, callerInvocationID: 0, actuals: [], limits: limits)
        ], limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: limits)
        let request = try MOSResolutionRequest(instance: "original-462-inspection", scope: declaration.scope,
            scopeInstantiation: 1, modelReference: declaration.name, profile: .pinnedNgspiceNormalV1,
            bindings: [], geometryScale: 1e-6, seed: 42, limits: limits)
        #expect(throws: MOSResolutionFailure.schema(.unsupportedRelease(level: 54, version: "4.62"))) {
            try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        }
        #expect(session.randomDraws == 0)
    }
}
