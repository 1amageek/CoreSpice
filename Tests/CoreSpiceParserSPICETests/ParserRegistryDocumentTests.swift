import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("Parser registry document dispatch", .timeLimit(.minutes(1)))
struct ParserRegistryDocumentTests {
    @Test func explicitUnsupportedFormatCannotFallBackToDetectedSPICE() async {
        let registry = ParserRegistry(parsers: [SPICEParser()])
        let result = await registry.parseFile(at: "requested.sp", format: "unsupported-format",
                                              fileResolver: DocumentResolver())
        #expect(result.hasErrors)
        #expect(result.netlist == nil)
    }

    @Test func fileDispatchPreservesTheResolverSelectedDocument() async throws {
        let registry = ParserRegistry(parsers: [SPICEParser()])
        let result = await registry.parseFile(at: "requested.sp", fileResolver: DocumentResolver())
        let model = try #require(try result.get().models.first)
        #expect(model.location?.file == "/selected/models.sp")
        #expect(model.location?.line == 2)
        #expect(model.origin?.captureID == "captured-source")
    }
}

private struct DocumentResolver: FileResolver {
    func readFile(at path: String) async throws -> SPICESourceDocument {
        SPICESourceDocument(text: "registry source\n.model sheet R r=100\n.end\n",
                            resolvedPath: "/selected/models.sp", captureID: "captured-source")
    }

    func resolveInclude(path: String, relativeTo: String?) async throws -> SPICESourceDocument {
        throw FileResolverError.fileNotFound(path: path)
    }

    func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> SPICESourceDocument {
        throw FileResolverError.fileNotFound(path: path)
    }
}
