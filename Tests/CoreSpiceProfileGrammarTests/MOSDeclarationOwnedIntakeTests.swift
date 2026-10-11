import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("Owned MOS declaration intake", .timeLimit(.minutes(1)))
struct MOSDeclarationOwnedIntakeTests {
    @Test(arguments: ["4.5", "4.50", "4.500000e+0", "4.500000E+0", "4.5k"])
    func numericVersionPreservesAccountedSourceSpelling(version: String) async throws {
        let resources = GrammarTestResources()
        do {
            let root = try document(".model n nmos level=54 version=\(version)\r\n+ tox={\"1e-9\"}\r\n.model p pmos level=54 version=\(version)",
                key: "exact-version", id: 0, resources: resources)
            let configuration = ParserConfiguration(resolveIncludes: true)
            let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "mos-intake-v1",
                configuration: configuration, resources: resources, maximumPageByteCount: 256)
            let result = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: environment, resolver: MOSIntakeResolver(text: "", resources: resources), resources: resources)
            #expect(result.netlist.models.count == 2)
            for model in result.netlist.models {
                #expect(model.parameters["version"] == .string(version))
                #expect(model.parameterAssignments[1].value == .string(version))
            }
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test(arguments: ["vto", "level", "version", "unknown", "0.5", "=0.5"])
    func malformedModelFieldsReleasePartialAccountedOwners(field: String) async throws {
        let resources = GrammarTestResources()
        do {
            let root = try document(".model n nmos kp=1m \(field)\n.end\n",
                key: "invalid-model", id: 0, resources: resources)
            let configuration = ParserConfiguration(resolveIncludes: true)
            let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "mos-intake-v1",
                configuration: configuration, resources: resources, maximumPageByteCount: 256)
            do {
                _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                    environment: environment, resolver: MOSIntakeResolver(text: "", resources: resources), resources: resources)
                Issue.record("Malformed model field published an owned snapshot")
            } catch let failure as SPICEProfileParseFailure {
                #expect(failure.diagnostic.location?.file == "invalid-model")
                #expect(failure.diagnostic.location?.line == 1)
                #expect(failure.diagnostic.severity == .error)
            }
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func repeatedIncludesRetainLocalFunctionAndAssignmentOccurrenceIdentity() async throws {
        let resources = GrammarTestResources()
        do {
            let root = try document(".subckt cell a b w=1u w=2u\n.include child\n.include child\n.ends\n", key: "root", id: 0, resources: resources)
            let child = ".param local=1\n.func localfn(x) {x+local}\n.model mf nmos level=54 version=4.8.1 vth0=.4 vth0=.5\nM1 a b 0 0 mf w=1u w=2u\n"
            let configuration = ParserConfiguration(resolveIncludes: true)
            let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "mos-intake-v1",
                configuration: configuration, resources: resources, maximumPageByteCount: 256)
            let result = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: environment, resolver: MOSIntakeResolver(text: child, resources: resources), resources: resources)
            let cell = try #require(result.netlist.subcircuits.first)
            #expect(result.netlist.functionDefinitions.isEmpty)
            #expect(result.netlist.controls.isEmpty)
            #expect(cell.body.functionDefinitions.map { $0.origin?.occurrenceID?.rawValue } == [1, 2])
            #expect(cell.body.functionDefinitions.allSatisfy { $0.origin?.captureID == "child" })
            #expect(cell.body.functionDefinitions.allSatisfy {
                $0.origin?.statementByteOffset == UInt64(".param local=1\n".utf8.count) && $0.origin?.statementOrdinal == 1
            })
            #expect(cell.body.parameterDefinitions.map { $0.origin?.occurrenceID?.rawValue } == [1, 2])
            #expect(cell.body.components.map { $0.origin?.occurrenceID?.rawValue } == [1, 2])
            #expect(cell.body.components.allSatisfy { $0.parameterAssignments.map(\.name) == ["w", "w"] })
            #expect(cell.body.models.map { $0.parameterAssignments.last?.origin?.occurrenceID?.rawValue } == [1, 2])
            #expect(cell.parameterAssignments.map { $0.origin?.occurrenceID?.rawValue } == [0, 0])
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func ownedMalformedBodyPublishesFailureAndReleasesPartialFunctionOwners() async throws {
        let resources = GrammarTestResources()
        do {
            let root = try document(".subckt broken a b\n.func leaked(x) {x+1}\nMbad a b 0 0 mf ic=1,2,3,4\n.ends\n", key: "broken", id: 0, resources: resources)
            let configuration = ParserConfiguration(resolveIncludes: true)
            let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "mos-intake-v1",
                configuration: configuration, resources: resources, maximumPageByteCount: 256)
            do {
                _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                    environment: environment, resolver: MOSIntakeResolver(text: "", resources: resources), resources: resources)
                Issue.record("Malformed MOS body must not publish a successful owned snapshot")
            } catch let failure as SPICEProfileParseFailure {
                #expect(failure.diagnostic.location?.file == "broken")
                #expect(failure.diagnostic.location?.line == 3)
                #expect(failure.diagnostic.severity == .error)
            }
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    private func document(_ text: String, key: String, id: UInt64,
                          resources: GrammarTestResources) throws -> SPICESourceDocument {
        try .init(accountedText: SPICEAccountedText.copy(text, resources: resources, maximumChunkByteCount: 256),
            sourceKey: key, occurrenceID: .init(id), resolvedPath: key)
    }
}

private actor MOSIntakeResolver: SPICEContextualFileResolver {
    let text: String
    let resources: GrammarTestResources
    private var nextOccurrence: UInt64 = 1
    init(text: String, resources: GrammarTestResources) { self.text = text; self.resources = resources }
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        guard request.literalRoute == "child" else { throw FileResolverError.fileNotFound(path: request.literalRoute) }
        let occurrence = nextOccurrence
        nextOccurrence += 1
        return try .init(accountedText: SPICEAccountedText.copy(text, resources: resources, maximumChunkByteCount: 256),
            sourceKey: "child", occurrenceID: .init(occurrence), resolvedPath: "child")
    }
}
