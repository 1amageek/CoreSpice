import CoreSpiceIO
import Testing

@Suite("Source and selected execution admission", .timeLimit(.minutes(1)))
struct SelectedExecutionAdmissionTests {
    @Test func unusedUnsupportedDefinitionsRetainDiagnosticsWithoutSelectingNumerics() async throws {
        let loaded = try await SPICEDeckLoader.load(source: """
        unused source definitions
        V1 out 0 1
        R1 out 0 1k
        .model unused C cox={missing}
        .subckt unused_body a
        .param impossible=undefined
        Cq a 0 q={also_missing*v(a)}
        .ends
        .op
        .end
        """)
        #expect(loaded.coverage.hasBlockedItems)
        #expect(loaded.coverage.items.contains { $0.kind == .model && $0.status == .blocked })
        #expect(loaded.coverage.items.contains { $0.kind == .component && $0.status == .blocked })
        let ir = try IOTestFrontend.lower(loaded.netlist)
        #expect(Set(ir.instances.map(\.name)) == Set(["v1", "r1"]))
        #expect(ir.instances.allSatisfy { $0.model == nil })
    }

    @Test func selectedUnsupportedDefinitionsFailInActualLowering() async throws {
        for declaration in ["Cq out 0 q={missing*v(out)}", "C1 out 0 cm\n.model cm C cap=1n",
                            ".subckt cell a\nCq a 0 q={missing*v(a)}\n.ends\nX1 out cell"] {
            let loaded = try await SPICEDeckLoader.load(source: "selected unsupported\n\(declaration)\n.op\n.end\n")
            #expect(loaded.coverage.hasBlockedItems)
            #expect(throws: LoweringError.self) { _ = try IOTestFrontend.lower(loaded.netlist) }
        }
    }

    @Test func rootIntentStillRefusesEvenWhenNestedInUnusedBody() async throws {
        for tail in [".alter R1 resistance=2k",
                     ".subckt unused a\n.alter R1 resistance=2k\n.ends",
                     ".subckt unused a\n.subckt inner b\n.alter R1 resistance=2k\n.ends\n.ends"] {
            do {
                _ = try await SPICEDeckLoader.load(source: "blocked root intent\nR1 out 0 1k\n\(tail)\n.op\n.end\n")
                Issue.record("Root execution intent bypassed intake")
            } catch let error as SPICEDeckLoadError {
                guard case .blockedExecutionIntent(let items) = error else { throw error }
                #expect(!items.isEmpty)
                #expect(items.contains { $0.name == "alter:r1.resistance" && $0.status == .blocked })
                #expect(items.allSatisfy { $0.kind != .model && $0.kind != .component })
            }
        }
    }

    @Test func actualScopesAndGlobalFailuresRetainTheirExistingAuthority() async throws {
        let loaded = try await SPICEDeckLoader.load(source: """
        actual scope
        .param cv=1n
        .model cv C cap={missing}
        .subckt cell a params: cv=2n
        C1 a 0 cv
        .model cv C cap={missing}
        .ends
        X1 out cell cv=3n
        .end
        """)
        let ir = try IOTestFrontend.lower(loaded.netlist)
        let cap = try #require(ir.instances.first)
        guard case .real(let value) = cap.parameters["c"] else { Issue.record("Missing actual capacitance"); return }
        #expect(value == 3 * 1e-9)
        #expect(cap.model == nil)
        let invalid = try await SPICEDeckLoader.load(source: "invalid global\n.param invalid=missing\nR1 out 0 1k\n.end\n")
        #expect(throws: MOSResolutionFailure.self) { _ = try IOTestFrontend.lower(invalid.netlist) }
    }
}
