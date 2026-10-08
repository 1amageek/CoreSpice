import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceParser
import Foundation

/// One load's immutable capture registry; repeated canonical paths reuse owned bytes.
public actor SPICECapturingFileResolver: FileResolver {
    private let pathResolver: LocalFileResolver
    private let reader: any SPICESourceReading
    public nonisolated let policy: SPICESourceCapturePolicy
    private var captures: [SPICESourceCapture] = []
    private struct ResolutionRequest: Hashable {
        let path: String
        let relativeTo: String?
    }
    private var resolvedRequests: [ResolutionRequest: String] = [:]
    private var capturesByPath: [String: SPICESourceCapture] = [:]
    private var totalByteCount: UInt64 = 0
    private var firstFailure: SPICESourceCaptureError?

    public init(includePaths: [String] = [], policy: SPICESourceCapturePolicy = .hostDefault,
                reader: any SPICESourceReading = LocalSPICESourceReader()) {
        pathResolver = LocalFileResolver(searchPaths: includePaths)
        self.policy = policy
        self.reader = reader
    }

    public func resolveInclude(path: String, relativeTo: String?) async throws -> SPICESourceDocument {
        let request = ResolutionRequest(path: path, relativeTo: relativeTo)
        if let selected = resolvedRequests[request], let capture = capturesByPath[selected] { return capture.document }
        let resolved = try await pathResolver.resolvedPath(for: path, relativeTo: relativeTo)
        let document = try readFile(at: resolved)
        resolvedRequests[request] = document.resolvedPath
        return document
    }

    public func resolveLibrary(path: String, section: String?, relativeTo: String?) async throws -> SPICESourceDocument {
        let document = try await resolveInclude(path: path, relativeTo: relativeTo)
        return try document.selectingLibrarySection(section)
    }

    public func readFile(at path: String) throws -> SPICESourceDocument {
        let canonical = Self.canonicalPath(path)
        if let capture = capturesByPath[canonical] { return capture.document }
        do {
            try admitSource()
            let bytes = try reader.read(at: canonical, maximumByteCount: policy.maximumTotalByteCount - totalByteCount,
                                        maximumPageByteCount: policy.maximumPageByteCount)
            return try register(bytes: bytes, path: canonical).document
        } catch {
            let failure = captureError(error, path: canonical)
            recordFailure(failure)
            throw failure
        }
    }

    public func captureMemory(_ source: String, fileName: String?) throws -> SPICESourceDocument {
        do {
            try admitSource()
            let byteCount = UInt64(source.utf8.count)
            try admitBytes(byteCount)
            return try register(bytes: Data(source.utf8), path: fileName.map(Self.canonicalPath)).document
        } catch {
            let failure = captureError(error, path: fileName ?? "<memory>")
            recordFailure(failure)
            throw failure
        }
    }

    public func capturedSources() -> [SPICESourceCapture] { captures }
    public func captureFailure() -> SPICESourceCaptureError? { firstFailure }

    private func admitSource() throws {
        guard UInt64(captures.count) < policy.maximumSourceCount else {
            throw SPICESourceCaptureError.sourceCountLimitExceeded(limit: policy.maximumSourceCount)
        }
    }

    private func admitBytes(_ count: UInt64) throws {
        guard count <= policy.maximumTotalByteCount - totalByteCount else {
            throw SPICESourceCaptureError.totalByteLimitExceeded(limit: policy.maximumTotalByteCount,
                                                                requested: totalByteCount + count)
        }
    }

    private func register(bytes: Data, path: String?) throws -> SPICESourceCapture {
        let count = UInt64(bytes.count)
        try admitBytes(count)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SPICESourceCaptureError.invalidUTF8(path: path ?? "<memory>")
        }
        let pageBytes = Int(policy.maximumPageByteCount)
        let updates = count == 0 ? 1 : (count - 1) / policy.maximumPageByteCount + 1
        let digest = try SHA256ContentDigester().digest(using: .sha256, limits: ContentDigestSessionLimits(
            maximumChunkByteCount: policy.maximumPageByteCount, maximumTotalByteCount: max(count, 1),
            maximumUpdateCount: updates
        )) { (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            var offset = 0
            while offset < bytes.count {
                let end = offset + min(pageBytes, bytes.count - offset)
                try lease.update(Array(bytes[offset..<end]))
                offset = end
            }
        }.digest
        let identity = try ArtifactID(digest: digest, byteCount: count)
        let capture = SPICESourceCapture(captureID: "\(identity.description):source:\(captures.count)",
                                        artifactID: identity, resolvedPath: path, bytes: bytes, text: text)
        captures.append(capture)
        if let path { capturesByPath[path] = capture }
        totalByteCount += count
        return capture
    }

    private func captureError(_ error: any Error, path: String) -> SPICESourceCaptureError {
        if let captureError = error as? SPICESourceCaptureError { return captureError }
        return .readFailed(path: path, reason: String(describing: error))
    }

    private func recordFailure(_ error: any Error) {
        if firstFailure == nil { firstFailure = error as? SPICESourceCaptureError }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
