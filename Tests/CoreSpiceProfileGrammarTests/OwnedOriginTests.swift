import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Bounded physical coordinates and origins")
struct OwnedOriginTests {
    @Test func physicalCoordinatesPreserveCRLFContinuationAndSelectedFullSourceOffsets() throws {
        let resources = GrammarTestResources()
        let text = ".lib slow\r\n.model m nmos (\r\n+ version=4.8)\r\n.endl slow\r\n"
        let document = try source(text, resources: resources)
        let selected = try document.selectingLibrarySection("slow", resources: resources)
        let coordinates = try SPICEPhysicalSourceCoordinates(document: selected, resources: resources)
        #expect(try coordinates.originalByteOffset(at: SourceLocation(file: "fixture", line: 2, column: 1), resources: resources) == 11)
        #expect(try coordinates.originalByteOffset(at: SourceLocation(file: "fixture", line: 3, column: 3), resources: resources) == 30)
        #expect(throws: SPICESourceStorageError.indexOutOfBounds) {
            try coordinates.originalByteOffset(at: SourceLocation(file: "fixture", line: 2, column: 200), resources: resources)
        }
    }

    @Test func coordinateQuotaCancellationAndUnicodeRefuseBeforePublication() throws {
        let resources = GrammarTestResources()
        let document = try source(".model m nmos\n", resources: resources)
        let refused = GrammarTestResources(liveLimit: 0)
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) {
            try SPICEPhysicalSourceCoordinates(document: document, resources: refused)
        }
        #expect(refused.used(.liveOwnedBytes) == 0)
        resources.setCancelled(true)
        #expect(throws: GrammarTestError.cancelled) {
            try SPICEPhysicalSourceCoordinates(document: document, resources: resources)
        }
        let unicodeResources = GrammarTestResources()
        let unicode = try source("* é\n", resources: unicodeResources)
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Unicode physical source coordinates")) {
            try SPICEPhysicalSourceCoordinates(document: unicode, resources: unicodeResources)
        }
    }

    @Test func repeatedContentOriginsRetainDistinctOccurrencesWithoutChangingLegacyID() {
        let location = SourceLocation(file: "fixture", line: 2, column: 1)
        let legacy = ParsedModelOrigin(captureID: "content", location: location, ordinal: 0)
        let first = ParsedModelOrigin(captureID: "content", location: location, ordinal: 0,
            occurrenceID: SPICEParseOccurrenceID(1), statementByteOffset: 17, statementOrdinal: 2)
        let second = ParsedModelOrigin(captureID: "content", location: location, ordinal: 0,
            occurrenceID: SPICEParseOccurrenceID(2), statementByteOffset: 17, statementOrdinal: 2)
        #expect(legacy.declarationID == "content:model:2:1:0")
        #expect(first.declarationID != second.declarationID)
        #expect(first.statementByteOffset == second.statementByteOffset)
        #expect(first != second)
    }

    private func source(_ text: String, resources: GrammarTestResources) throws -> SPICESourceDocument {
        let owned = try SPICEAccountedText.copy(text, resources: resources, maximumChunkByteCount: 256)
        return try SPICESourceDocument(accountedText: owned, sourceKey: "content",
            occurrenceID: SPICEParseOccurrenceID(0), resolvedPath: "fixture")
    }
}
