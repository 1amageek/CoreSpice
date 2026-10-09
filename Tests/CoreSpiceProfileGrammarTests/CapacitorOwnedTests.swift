import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Bounded capacitor source grammar")
struct CapacitorOwnedTests {
    @Test func sourceRolesMatchOrdinaryGrammarAndReleaseAllOwners() async throws {
        let resources = GrammarTestResources()
        let text = """
        capacitor profile
        .param cv=5n
        C1 a 0 cm
        C2 a 0 cv
        C3 a 0 cm 2n
        C4 a 0 2n cm 4n
        C5 a 0 cm c=cv*(1+tc*(temper-tref))+
        + max(v(a),v(b))*scale m=2
        C6 a 0 {cv}
        C7 a 0 'cv'
        C8 a 0 c=cv
        .model cm C cox=1 capsw=2 w=3 tnom=25 tc1=.01 tc2=.001
        .model cv C cap=6n
        .subckt cell a params: cv=7n
        C9 a 0 cv
        .model cv C cap=8n
        .ends
        .end
        """
        let ordinary = try await SPICEParser().parse(source: text, fileName: "capacitor-profile").get()
        do {
            let document = try source(text, resources: resources)
            let configuration = ParserConfiguration(resolveIncludes: true)
            let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "capacitor-policy",
                configuration: configuration, resources: resources, maximumPageByteCount: 256)
            let result = try await SPICEParser().parseProfile(document: document, configuration: configuration,
                environment: environment, resolver: CapacitorNoDependencyResolver(), resources: resources)
            #expect(result.netlist.components == ordinary.components)
            #expect(result.netlist.subcircuits[0].body.components == ordinary.subcircuits[0].body.components)
            for (owned, plain) in zip(result.netlist.models, ordinary.models) {
                #expect(owned.type == plain.type)
                #expect(owned.parameters == plain.parameters)
                #expect(owned.origin?.occurrenceID == SPICEParseOccurrenceID(0))
                #expect(owned.origin?.statementByteOffset != nil)
                #expect(owned.origin?.statementOrdinal != nil)
            }
            #expect(result.netlist.components[0].passiveModelCandidate == "cm")
            #expect(result.netlist.components[1].passiveModelCandidate == "cv")
            #expect(result.netlist.components[2].modelName == "cm")
            #expect(resources.work(.retainedElements) > 0)
            #expect(resources.used(.liveOwnedBytes) > 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func malformedTailRefusesOwnedPublicationAndReleasesFailureOwner() async throws {
        for card in ["C1 a 0 c=2n cm", "C1 a 0 cm 2n 3n", "C1 a 0 c=cv stray m=2",
                     "C1 a 0 c=cv*\n+ (temper-)"] {
            let resources = GrammarTestResources()
            do {
                let document = try source("bad capacitor\n\(card)\n.end\n", resources: resources)
                let configuration = ParserConfiguration(resolveIncludes: true)
                let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "capacitor-policy",
                    configuration: configuration, resources: resources, maximumPageByteCount: 256)
                do {
                    _ = try await SPICEParser().parseProfile(document: document, configuration: configuration,
                        environment: environment, resolver: CapacitorNoDependencyResolver(), resources: resources)
                    Issue.record("Expected malformed capacitance refusal")
                } catch let failure as SPICEProfileParseFailure {
                    #expect(failure.diagnostic.severity == .error)
                    #expect(failure.diagnostic.location?.file == "capacitor-profile")
                }
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
    }

    private func source(_ text: String, resources: GrammarTestResources) throws -> SPICESourceDocument {
        try SPICESourceDocument(accountedText: SPICEAccountedText.copy(text, resources: resources,
            maximumChunkByteCount: 256), sourceKey: "capacitor-profile", occurrenceID: .init(0),
            resolvedPath: "capacitor-profile")
    }
}

private struct CapacitorNoDependencyResolver: SPICEContextualFileResolver {
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        throw ParserDiagnostic.error("Unexpected dependency in capacitor fixture")
    }
}
