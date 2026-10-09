import CoreSpiceIR
import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import CoreSpiceLowering
import Testing

@Suite("Capacitor scoped source admission", .timeLimit(.minutes(1)))
struct CapacitorLoweringTests {
    @Test func parameterPresenceWinsOverSameNameModelInEveryInvocation() async throws {
        let parsed = try await SPICEParser().parse(source: """
        scoped capacitor values
        .param cv=1n
        .model cv C cox={unused}
        .subckt cell a params: cv=2n
        C1 a 0 cv
        .ends
        Croot root 0 cv
        X1 first cell
        X2 second cell cv=3n
        .end
        """).get()
        let ir = try NetlistLowering().lower(parsed)
        for (name, value) in [("croot", 1e-9), ("x1.c1", 2e-9), ("x2.c1", 3 * 1e-9)] {
            let instance = try #require(ir.instances.first { $0.name.lowercased() == name })
            #expect(instance.model == nil)
            #expect(scalar(instance.parameters["c"]) == value)
        }
    }

    @Test func includedBareRoleWaitsForGlobalParameterAndNeverLeaksBetweenScopes() async throws {
        let root = try await SPICEParser().parse(source: """
        included capacitor role
        .include "cell.inc"
        .param cv=4n
        .model cv C cox={unused}
        X1 out cell
        .end
        """, fileName: "root.cir", configuration: .init(resolveIncludes: true),
            fileResolver: IncludeResolver()).get()
        let ir = try NetlistLowering().lower(root)
        let cap = try #require(ir.instances.first)
        #expect(cap.model == nil)
        #expect(scalar(cap.parameters["c"]) == 4e-9)
    }

    @Test func unresolvedModelReferenceAndDisabledEvaluationNeverBecomeIdealCapacitors() async throws {
        for tail in ["cm", "cm 1p", "cm c=2p", "1p cm", "{cv} cm"] {
            let parsed = try await SPICEParser().parse(source:
                "model backed capacitor\n.param cv=3p\nC1 out 0 \(tail)\n.model cm C cox={unused}\n.end\n").get()
            for expand in [true, false] {
                do {
                    _ = try NetlistLowering(configuration: .init(expandModels: expand)).lower(parsed)
                    Issue.record("Model-backed capacitor returned an ideal instance")
                } catch let error as LoweringError {
                    guard case .invalidComponent(_, let reason) = error else { throw error }
                    #expect(reason == "Model-backed capacitor execution is not implemented")
                }
            }
        }
        let ambiguous = try await SPICEParser().parse(source:
            "disabled parameter evaluation\n.param cv=1p\nC1 a 0 cv\n.model cv C cap=9p\n.end\n").get()
        #expect(throws: LoweringError.self) {
            _ = try NetlistLowering(configuration: .init(evaluateExpressions: false)).lower(ambiguous)
        }
        let ir = try NetlistLowering(configuration: .init(evaluateExpressions: false,
            parameterOverrides: ["cv": 2e-12])).lower(ambiguous)
        #expect(ir.instances.first?.model == nil)
        #expect(scalar(ir.instances.first?.parameters["c"]) == 2e-12)
    }

    @Test func wrongMissingAndLocalModelsFailBeforeParameterFlattening() async throws {
        for source in [
            "C1 out 0 1p bad\n.model bad R r=10",
            "C1 out 0 1p missing",
            ".subckt cell a\nC1 a 0 cm\n.model cm C cap=1p\n.ends\nX1 out cell"
        ] {
            let parsed = try await SPICEParser().parse(source: "capacitor refusal\n\(source)\n.end\n").get()
            #expect(throws: LoweringError.self) { _ = try NetlistLowering().lower(parsed) }
        }
    }

    private func scalar(_ value: ParameterValue?) -> Double? {
        guard case .real(let number) = value else { return nil }
        return number
    }

    private struct IncludeResolver: FileResolver {
        func resolveInclude(path: String, relativeTo: String?) async throws -> SPICESourceDocument {
            guard path == "cell.inc" else { throw FileResolverError.fileNotFound(path: path) }
            return SPICESourceDocument(text: ".subckt cell a\nC1 a 0 cv\n.ends\n", resolvedPath: path)
        }
        func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> SPICESourceDocument {
            throw FileResolverError.fileNotFound(path: path)
        }
        func readFile(at path: String) async throws -> SPICESourceDocument {
            throw FileResolverError.fileNotFound(path: path)
        }
    }
}
