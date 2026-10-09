import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Bounded charge capacitor grammar")
struct ChargeCapacitorOwnedTests {
    @Test func fullChargeLawsMatchOrdinaryASTAndReleaseOwners() async throws {
        let law = "cmin*vm*(v(c0)-v(p2))+((0.5*(cmax+cmin)-cmin)*(v(c0)-v(p2))+0.5*(cmax-cmin)*(1/1.9)*(cnwvc_slope1*log(cosh((v(c0)-v(p2)-cnwvc_vt1)/cnwvc_slope1))+0.9*cnwvc_slope2*log(cosh((v(c0)-v(p2)-cnwvc_vt2)/cnwvc_slope2))))*vm"
        let text = """
        owned charge law
        cq c0 p2 q='\(law)'
        cbraced c0 p2 q={\(law)}
        cnamed c0 p2 q=\(law)
        cnumeric c0 p2 q={2p}
        .subckt cell a b params: scale=2
        .param q0=1p
        cbody a b q=q0*(v(a)-v(b))+
        + max(v(a),v(b))*scale
        .ends
        .end
        """
        let ordinary = try await SPICEParser().parse(source: text, fileName: "charge-profile").get()
        let resources = GrammarTestResources()
        do {
            let document = try source(text, resources: resources)
            let configuration = ParserConfiguration(resolveIncludes: true)
            let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "charge-policy",
                configuration: configuration, resources: resources, maximumPageByteCount: 256)
            let result = try await SPICEParser().parseProfile(document: document, configuration: configuration,
                environment: environment, resolver: ChargeNoDependencyResolver(), resources: resources)
            expectComponentSemanticParity(owned: result.netlist.components, ordinary: ordinary.components)
            let ownedCell = try #require(result.netlist.subcircuits.first)
            let ordinaryCell = try #require(ordinary.subcircuits.first)
            expectComponentSemanticParity(owned: ownedCell.body.components, ordinary: ordinaryCell.body.components)
            #expect(result.netlist.subcircuits.first?.origin?.occurrenceID == SPICEParseOccurrenceID(0))
            for component in result.netlist.components {
                #expect(component.parameters.count == 1)
                #expect(component.parameters["q"] != nil)
                #expect(component.modelName == nil)
                #expect(component.passiveModelCandidate == nil)
            }
            #expect(resources.work(.retainedElements) > 0)
            #expect(resources.used(.liveOwnedBytes) > 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func malformedAndMixedChargeFormsRefusePublicationAndReleaseOwners() async throws {
        for tail in ["q=2p", "q=", "q={v(a)} q={v(a)}", "q={v(a)} c=1p", "c=1p q={v(a)}",
                     "q={v(a)} 1p", "1p q={v(a)}", "cm q={v(a)}", "q={v(a)} cm",
                     "m=2 q={v(a)}", "q={v(a)} m=2", "q=q0 stray", "q=q0*\n+ (v(a)-)"] {
            let text = "bad owned charge\ncq a 0 \(tail)\n.model cm C cap=2p\n.end\n"
            let ordinary = await SPICEParser().parse(source: text, fileName: "charge-profile")
            #expect(!ordinary.isSuccess)
            let resources = GrammarTestResources()
            do {
                let document = try source(text, resources: resources)
                let configuration = ParserConfiguration(resolveIncludes: true)
                let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "charge-policy",
                    configuration: configuration, resources: resources, maximumPageByteCount: 256)
                do {
                    _ = try await SPICEParser().parseProfile(document: document, configuration: configuration,
                        environment: environment, resolver: ChargeNoDependencyResolver(), resources: resources)
                    Issue.record("Expected charge source refusal")
                } catch let failure as SPICEProfileParseFailure {
                    #expect(failure.diagnostic.severity == .error)
                    #expect(failure.diagnostic.location?.file == "charge-profile")
                    #expect(failure.diagnostic.location?.line == (tail.contains("\n") ? 3 : 2))
                    #expect(ordinary.diagnostics.contains { $0.location == failure.diagnostic.location })
                }
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
    }

    private func source(_ text: String, resources: GrammarTestResources) throws -> SPICESourceDocument {
        try SPICESourceDocument(accountedText: SPICEAccountedText.copy(text, resources: resources,
            maximumChunkByteCount: 256), sourceKey: "charge-profile", occurrenceID: .init(0), resolvedPath: "charge-profile")
    }
}

private struct ChargeNoDependencyResolver: SPICEContextualFileResolver {
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        throw ParserDiagnostic.error("Unexpected dependency in charge fixture")
    }
}
