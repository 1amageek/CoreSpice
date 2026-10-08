import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import Foundation
import Testing

@Suite("Checked Span source and document ownership")
struct CheckedSpanSourceTests {
    private func binding(_ bytes: [UInt8], key: String = "root") throws -> SPICEExactSourceBinding {
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: ContentDigestSessionLimits(maximumChunkByteCount: UInt64(max(1, bytes.count)),
                maximumTotalByteCount: UInt64(max(1, bytes.count)), maximumUpdateCount: 1)) {
                    (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            if !bytes.isEmpty { try lease.update(bytes) }
        }
        return SPICEExactSourceBinding(key: key, reference: try ArtifactReference(digest: digest.digest,
            byteCount: UInt64(bytes.count), descriptor: ArtifactDescriptor(role: .input, kind: .netlist, format: .spice)))
    }

    @Test func sameBytesHashCountAndIndependentOccurrencesRetainFinalOwner() throws {
        var bytes = Array("title\n.model active R r=1\n".utf8)
        let expected = try binding(bytes)
        let resources = SourceBoundaryTestResources()
        var source: SPICECheckedSource? = try .admit(binding: expected, bytes: bytes.span, resources: resources, maximumPageByteCount: 3)
        var first: SPICESourceDocument? = try source!.document(expectedBinding: expected, occurrenceID: .init(0))
        var second: SPICESourceDocument? = try source!.document(expectedBinding: expected, occurrenceID: .init(1))
        #expect(first!.occurrenceID != second!.occurrenceID)
        #expect(first!.captureID == second!.captureID)
        #expect(source!.binding == expected && resources.hashedBytes == UInt64(bytes.count))
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.used(.liveOwnedBytes) == UInt64(bytes.count * 2))
        let original = bytes; bytes[0] = 88
        #expect(source!.bytes == Data(original))
        source = nil; first = nil
        #expect(resources.used(.liveOwnedBytes) == UInt64(original.count * 2))
        withExtendedLifetime(second) {}
        second = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func sameLengthDriftAndCompleteDescriptorMismatchRefusePublication() throws {
        let bytes = Array("title\n.end\n".utf8)
        let expected = try binding(bytes)
        var changed = bytes; changed[0] = 88
        let resources = SourceBoundaryTestResources()
        #expect(throws: SPICEExactSourceError.sourceDrift("root")) {
            _ = try SPICECheckedSource.admit(binding: expected, bytes: changed.span, resources: resources, maximumPageByteCount: 4)
        }
        #expect(resources.used(.liveOwnedBytes) == 0 && resources.used(.temporaryBytes) == 0)
        let source = try SPICECheckedSource.admit(binding: expected, bytes: bytes.span, resources: resources, maximumPageByteCount: 4)
        let wrong = SPICEExactSourceBinding(key: "root", reference: ArtifactReference(id: expected.reference.id,
            descriptor: ArtifactDescriptor(role: .output, kind: .model, format: .spice)))
        #expect(throws: SPICEExactSourceError.sourceDrift("root")) {
            _ = try source.document(expectedBinding: wrong, occurrenceID: .init(0))
        }
    }

    @Test func capacityHashAndCancellationFailuresPreserveTheirTypedCause() throws {
        let bytes = Array("title\n.end\n".utf8)
        let expected = try binding(bytes)
        let refused = SourceBoundaryTestResources(liveLimit: 0)
        #expect(throws: SourceBoundaryTestError.limit(.liveOwnedBytes)) {
            _ = try SPICECheckedSource.admit(binding: expected, bytes: bytes.span, resources: refused, maximumPageByteCount: 2)
        }
        #expect(refused.hashedBytes == 0 && refused.used(.liveOwnedBytes) == 0)
        let hashRefused = SourceBoundaryTestResources(hashLimit: 2)
        #expect(throws: SourceBoundaryTestError.hashLimit) {
            _ = try SPICECheckedSource.admit(binding: expected, bytes: bytes.span, resources: hashRefused, maximumPageByteCount: 2)
        }
        #expect(hashRefused.hashedBytes == 2)
        #expect(hashRefused.used(.liveOwnedBytes) == 0 && hashRefused.used(.temporaryBytes) == 0)
        let cancelled = SourceBoundaryTestResources(); cancelled.setCancelled(true)
        #expect(throws: SourceBoundaryTestError.cancelled) {
            _ = try SPICECheckedSource.admit(binding: expected, bytes: bytes.span, resources: cancelled, maximumPageByteCount: 2)
        }
        #expect(cancelled.used(.liveOwnedBytes) == 0 && cancelled.hashedBytes == 0)
    }

    @Test(arguments: [[UInt8](arrayLiteral: 0xC0, 0x80), [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]])
    func strictUTF8NeverRepairsInvalidInput(_ bytes: [UInt8]) throws {
        let expected = try binding(bytes), resources = SourceBoundaryTestResources()
        #expect(throws: SPICEExactSourceError.invalidUTF8("root")) {
            _ = try SPICECheckedSource.admit(binding: expected, bytes: bytes.span, resources: resources, maximumPageByteCount: 2)
        }
        #expect(resources.used(.liveOwnedBytes) == 0 && resources.used(.temporaryBytes) == 0)
    }

    @Test func validUnicodeScalarChunkingPreservesExactUTF8AndOffsets() throws {
        let bytes = Array("é e\u{301} 🐈\r\n".utf8), resources = SourceBoundaryTestResources()
        let expected = try binding(bytes)
        let source = try SPICECheckedSource.admit(binding: expected, bytes: bytes.span, resources: resources, maximumPageByteCount: 1)
        let document = try source.document(expectedBinding: expected, occurrenceID: .init(2))
        #expect(Array(document.text.utf8) == bytes)
        #expect(try document.originalByteOffset(for: 5, resources: resources) == 5)
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Unicode library selection")) {
            _ = try document.selectingLibrarySection("tt", resources: resources)
        }
    }

    @Test func accountedSectionKeepsOriginalCRLFAndContinuationBytePositions() throws {
        let text = "* header\r\n.lib ff\r\n.model unused D\r\n.endl\r\n.lib TT\r\n.model active R r=1\r\n+ tc1=2\r\n.endl\r\n"
        let bytes = Array(text.utf8), resources = SourceBoundaryTestResources()
        let expected = try binding(bytes)
        var source: SPICECheckedSource? = try .admit(binding: expected, bytes: bytes.span, resources: resources, maximumPageByteCount: 7)
        var document: SPICESourceDocument? = try source!.document(expectedBinding: expected, occurrenceID: .init(9))
        var selected: SPICESourceDocument? = try document!.selectingLibrarySection("tT", resources: resources)
        #expect(selected!.librarySection == "tT" && selected!.occurrenceID == .init(9))
        #expect(selected!.text.contains(".model active") && !selected!.text.contains("unused"))
        for needle in [".model active", "+ tc1=2"] {
            let original = text.range(of: needle)!, projected = selected!.text.range(of: needle)!
            let originalOffset = text.utf8.distance(from: text.utf8.startIndex, to: original.lowerBound)
            let projectedOffset = selected!.text.utf8.distance(from: selected!.text.utf8.startIndex, to: projected.lowerBound)
            #expect(try selected!.originalByteOffset(for: UInt64(projectedOffset), resources: resources) == UInt64(originalOffset))
        }
        #expect(selected!.text.filter { $0 == "\r\n" }.count == text.filter { $0 == "\r\n" }.count)
        source = nil; document = nil
        #expect(resources.used(.liveOwnedBytes) > 0 && resources.used(.temporaryBytes) == 0)
        withExtendedLifetime(selected) {}; selected = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func countOnlySourcesCannotProduceAnAccountedDocument() throws {
        let bytes = Array("title\n.end\n".utf8), resources = SourceBoundaryTestResources()
        let expected = try binding(bytes)
        let source = try SPICECheckedSource.admit(binding: expected, bytes: Data(bytes), work: resources, maximumPageByteCount: 3)
        #expect(!source.isInvocationAccounted)
        #expect(throws: SPICEBoundedSourceError.unaccountedSource) {
            _ = try source.document(expectedBinding: expected, occurrenceID: .init(0))
        }
        let doc = SPICESourceDocument(text: ".lib tt\n.model r R\n.endl\n", captureID: "root")
        #expect(throws: SPICEBoundedSourceError.unaccountedSource) { _ = try doc.selectingLibrarySection("tt", resources: resources) }
    }
}
