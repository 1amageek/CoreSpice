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
        let ir = try FrontendTestLowering().lower(parsed)
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
        let ir = try FrontendTestLowering().lower(root)
        let cap = try #require(ir.instances.first)
        #expect(cap.model == nil)
        #expect(scalar(cap.parameters["c"]) == 4e-9)
    }

    @Test func selectedModelKeepsItsCoefficientOwnerWithOrWithoutExplicitCapacitance() async throws {
        for tail in ["cm", "cm 1p", "cm c=2p", "1p cm", "{cv} cm"] {
            let parsed = try await SPICEParser().parse(source:
                "model backed capacitor\n.param cv=3p\nC1 out 0 \(tail)\n.model cm C cap=9p\n.end\n").get()
            for expand in [true, false] {
                let ir = try FrontendTestLowering(configuration: .init(expandModels: expand)).lower(parsed)
                let instance = try #require(ir.instances.first)
                #expect(instance.model?.name == "cm")
                #expect(instance.parameters["cap"] == nil)
                #expect(scalar(instance.model?.parameters["cap"]) == 9e-12)
            }
        }
        let ambiguous = try await SPICEParser().parse(source:
            "parameter precedence\n.param cv=1p\nC1 a 0 cv\n.model cv C cap=9p\n.end\n").get()
        let ir = try FrontendTestLowering(configuration: .init(parameterOverrides: ["cv": 2e-12])).lower(ambiguous)
        #expect(ir.instances.first?.model == nil)
        #expect(scalar(ir.instances.first?.parameters["c"]) == 2e-12)
    }

    @Test func wrongAndMissingModelsFailBeforeParameterFlattening() async throws {
        for source in ["C1 out 0 1p bad\n.model bad R r=10", "C1 out 0 1p missing"] {
            let parsed = try await SPICEParser().parse(source: "capacitor refusal\n\(source)\n.end\n").get()
            #expect(throws: LoweringError.self) { _ = try FrontendTestLowering().lower(parsed) }
        }
        let scoped = try await SPICEParser().parse(source:
            "local source model\n.subckt cell a\nC1 a 0 cm\n.model cm C cap=1p\n.ends\nX1 out cell\n.end\n").get()
        #expect(try FrontendTestLowering().lower(scoped).instances.first?.model?.name == "cm")
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
