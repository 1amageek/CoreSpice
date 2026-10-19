import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceParsedIR
import CoreSpiceParser
import Foundation

/// Local selection authority for resource-aware batch intake; parsing remains in ParserSPICE.
internal actor SPICEAccountedFileResolver: SPICEContextualFileResolver {
    private struct Entry: Sendable {
        let source: SPICECheckedSource
        let capture: SPICESourceCapture
    }
    private let paths: LocalFileResolver
    private let policy: SPICESourceCapturePolicy
    private let reader: any SPICESourceReading
    private let resources: any SPICESourceResourceAccounting
    private var entries = SPICEAccountedCollection<Entry>(storageKind: .liveOwnedBytes)
    private var totalBytes: UInt64 = 0
    private var nextOccurrence: UInt64 = 1

    init(includePaths: [String], policy: SPICESourceCapturePolicy, reader: any SPICESourceReading,
         resources: any SPICESourceResourceAccounting) {
        paths = LocalFileResolver(searchPaths: includePaths)
        self.policy = policy; self.reader = reader; self.resources = resources
    }

    func root(at path: String) throws -> SPICESourceDocument {
        let source = try acquire(path)
        return try source.document(expectedBinding: source.binding, occurrenceID: .init(0), resolvedPath: path)
    }

    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        try resources.checkCancellation()
        try resources.charge(.retainedElements, units: 1)
        let selected = try await paths.resolvedPath(for: request.literalRoute, relativeTo: request.parentSourceKey)
        let path = URL(fileURLWithPath: selected).standardizedFileURL.resolvingSymlinksInPath().path
        let source = try acquire(path)
        let occurrence = nextOccurrence
        let (next, overflow) = nextOccurrence.addingReportingOverflow(1)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        nextOccurrence = next
        return try source.document(expectedBinding: source.binding, occurrenceID: .init(occurrence), resolvedPath: path)
            .selectingLibrarySection(request.requestedChildSection, resources: resources)
    }

    private func acquire(_ path: String) throws -> SPICECheckedSource {
        try resources.checkCancellation()
        for entry in entries {
            try resources.charge(.retainedElements, units: 1)
            if entry.source.binding.key == path { return entry.source }
        }
        guard UInt64(entries.count) < policy.maximumSourceCount else {
            throw SPICESourceCaptureError.sourceCountLimitExceeded(limit: policy.maximumSourceCount)
        }
        // Metadata inspection precedes content I/O and establishes the exact read admission.
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
            throw SPICESourceCaptureError.readFailed(path: path, reason: "Missing representable file size")
        }
        let byteCount = size.uint64Value
        guard byteCount <= policy.maximumTotalByteCount - totalBytes else {
            let (requested, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
            throw SPICESourceCaptureError.totalByteLimitExceeded(limit: policy.maximumTotalByteCount, requested: requested)
        }
        try resources.charge(.sourceBytes, units: byteCount)
        try resources.chargeHashedBytes(byteCount)
        let (payloadBytes, overflow) = byteCount.multipliedReportingOverflow(by: 2)
        let (scratchBytes, headerOverflow) = payloadBytes.addingReportingOverflow(64)
        guard !overflow, !headerOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
        let readOwner = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: byteCount)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: scratchBytes)
        defer { withExtendedLifetime((readOwner, scratch)) {} }
        let bytes = try reader.read(at: path, maximumByteCount: byteCount, maximumPageByteCount: policy.maximumPageByteCount)
        guard UInt64(bytes.count) == byteCount else { throw SPICESourceCaptureError.sourceChangedDuringRead(path: path) }
        try resources.charge(.projectedBytes, units: byteCount)
        let array = Array(bytes)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: max(1, byteCount), maximumTotalByteCount: max(1, byteCount), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(array)
        }
        let reference = try ArtifactReference(digest: digest.digest, byteCount: byteCount,
            descriptor: .init(role: .input, kind: .netlist, format: .spice))
        let source = try SPICECheckedSource.admit(binding: .init(key: path, reference: reference),
            bytes: array.span, resources: resources, maximumPageByteCount: policy.maximumPageByteCount)
        let capture = SPICESourceCapture(captureID: path, artifactID: reference.id, resolvedPath: path,
            bytes: source.bytes, text: source.text)
        try entries.append(.init(source: source, capture: capture), resources: resources)
        totalBytes += byteCount
        return source
    }

    func reserveCoverage(_ netlist: ParsedNetlist) throws -> SPICESourceStorageReservation {
        var count = 1
        for extent in [netlist.components.count, netlist.models.count, netlist.controls.count,
                       netlist.parameterDefinitions.count, netlist.parameters.count,
                       netlist.preprocessingEvents.count, netlist.analyses.count, entries.count] {
            let (next, overflow) = count.addingReportingOverflow(extent)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }; count = next
        }
        let (work, workOverflow) = UInt64(count).multipliedReportingOverflow(by: UInt64(count))
        let (bytes, byteOverflow) = UInt64(count).multipliedReportingOverflow(by: 4096)
        guard !workOverflow, !byteOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
        try resources.charge(.retainedElements, units: work)
        return try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
    }

    func capturedSources() throws -> [SPICESourceCapture] {
        var result: [SPICESourceCapture] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            try resources.charge(.retainedElements, units: 1)
            result.append(entry.capture)
        }
        return result
    }
}
