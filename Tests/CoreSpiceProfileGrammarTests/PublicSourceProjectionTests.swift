import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("Public bounded source projections")
struct PublicSourceProjectionTests {
    @Test func publicFormatterMatchesExactExistingExpressionMeaning() throws {
        let formatter: any SPICEExpressionFormatting = SPICEExpressionFormatter()
        let expression = ParsedExpression.conditional(
            condition: .binaryOperation(.greaterThan, .identifier("width"), .literal(0)),
            then: .functionCall(name: "max", arguments: [.literal(1), .unaryOperation(.negate, .identifier("bias"))]),
            else: .binaryOperation(.power, .identifier("scale"), .literal(2)))
        let resources = GrammarTestResources()
        let result = try formatter.format(expression: expression, resources: resources)
        #expect(result.text == expression.description)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.work(.lexicalBytes) > 0)
    }

    @Test func longNameCapacityUnicodeAndCancellationRefuseBeforePublicOutput() throws {
        let name = String(repeating: "long_name", count: 200)
        let resources = GrammarTestResources(liveLimit: UInt64(name.utf8.count - 1))
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) {
            try SPICEExpressionFormatter().format(expression: .identifier(name), resources: resources)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.work(.projectedBytes) == 0)
        #expect(resources.work(.lexicalBytes) == UInt64(name.utf8.count))
        let unicode = GrammarTestResources()
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode expression formatting")) {
            try SPICEExpressionFormatter().format(expression: .identifier("é"), resources: unicode)
        }
        #expect(unicode.used(.liveOwnedBytes) == 0)
        let cancelled = GrammarTestResources()
        cancelled.setCancelled(true)
        #expect(throws: GrammarTestError.cancelled) {
            try SPICEExpressionFormatter().format(expression: .identifier(name), resources: cancelled)
        }
        #expect(cancelled.used(.liveOwnedBytes) == 0)
    }

    @Test func publicFormattedCopiesRetainActualTextUntilFinalOwnerRelease() throws {
        let resources = GrammarTestResources()
        var original: SPICEOwnedExpressionText? = try SPICEExpressionFormatter().format(
            expression: .identifier(String(repeating: "owned", count: 100)), resources: resources)
        let charged = resources.used(.liveOwnedBytes)
        #expect(charged > 500)
        var copy = original
        original = nil
        withExtendedLifetime(copy) { #expect(resources.used(.liveOwnedBytes) == charged) }
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func publicPhysicalProjectionMapsCRLFSectionAndContinuationToFullSource() throws {
        let resources = GrammarTestResources()
        let text = ".lib slow\r\n.model m nmos (\r\n+ version=4.8)\r\n.endl slow\r\n"
        let full = try document(text, resources: resources)
        let selected = try full.selectingLibrarySection("slow", resources: resources)
        let baseline = resources.used(.liveOwnedBytes)
        #expect(try selected.originalByteOffset(at: .init(file: "diagnostic-label", line: 2, column: 1), resources: resources) == 11)
        #expect(try selected.originalByteOffset(at: .init(file: "diagnostic-label", line: 3, column: 3), resources: resources) == 30)
        #expect(resources.used(.liveOwnedBytes) == baseline)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func publicPhysicalProjectionChecksBoundsAndRefusesIndexCapacity() throws {
        let resources = GrammarTestResources()
        let source = try document(".model m nmos\r\n", resources: resources)
        for position in [SourceLocation(file: "source", line: 0, column: 1),
                         SourceLocation(file: "source", line: 3, column: 1),
                         SourceLocation(file: "source", line: 1, column: 100)] {
            #expect(throws: SPICESourceStorageError.indexOutOfBounds) {
                try source.originalByteOffset(at: position, resources: resources)
            }
        }
        let refused = GrammarTestResources(liveLimit: 0)
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) {
            try source.originalByteOffset(at: .init(file: "source", line: 1, column: 1), resources: refused)
        }
        #expect(refused.used(.liveOwnedBytes) == 0)
        #expect(throws: SPICEBoundedSourceError.unaccountedSource) {
            try SPICESourceDocument(text: "x").originalByteOffset(at: .init(file: "source", line: 1, column: 1), resources: resources)
        }
    }

    private func document(_ text: String, resources: GrammarTestResources) throws -> SPICESourceDocument {
        try SPICESourceDocument(accountedText: SPICEAccountedText.copy(text, resources: resources,
            maximumChunkByteCount: 256), sourceKey: "content", occurrenceID: .init(0), resolvedPath: "source")
    }
}
