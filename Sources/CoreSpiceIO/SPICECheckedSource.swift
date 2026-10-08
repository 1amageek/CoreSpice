import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceParsedIR
import CoreSpiceParser
import Foundation

/// An immutable full-file input owner. Only checked byte admission can construct it.
public struct SPICECheckedSource: Sendable {
    public let binding: SPICEExactSourceBinding
    public let bytes: Data
    let text: String
    private let byteReservation: SPICESourceStorageReservation?
    private let accountedText: SPICEAccountedText?
    public var isInvocationAccounted: Bool { byteReservation != nil && accountedText != nil }

    private init(binding: SPICEExactSourceBinding, bytes: Data, text: String) {
        self.binding = binding
        self.bytes = bytes
        self.text = text
        self.byteReservation = nil; self.accountedText = nil
    }

    /// Checks the complete reference's digest/count against exactly the supplied bytes.
    /// Admission costs belong to the provider's invocation accountant before hashing/decoding.
    public static func admit(binding: SPICEExactSourceBinding, bytes: Data,
                             work: any SPICESourceWorkAccounting,
                             maximumPageByteCount: UInt64) throws -> Self {
        guard !binding.key.isEmpty else { throw SPICEExactSourceError.invalidSourceKey }
        guard maximumPageByteCount > 0, maximumPageByteCount <= UInt64(Int.max) else {
            throw SPICEExactSourceError.invalidPolicy
        }
        guard binding.reference.digest.algorithm == .sha256 else {
            throw SPICEExactSourceError.unsupportedDigest(binding.key)
        }
        guard UInt64(bytes.count) == binding.reference.byteCount else {
            throw SPICEExactSourceError.sourceDrift(binding.key)
        }
        try work.charge(.sourceBytes, units: UInt64(bytes.count))
        try work.charge(.projectedBytes, units: UInt64(bytes.count))
        let page = Int(maximumPageByteCount)
        let count = UInt64(bytes.count)
        var cancellation: (any Error)?
        let result: ContentDigestResult
        do {
            result = try SHA256ContentDigester().digest(using: .sha256,
                limits: ContentDigestSessionLimits(maximumChunkByteCount: maximumPageByteCount,
                    maximumTotalByteCount: max(1, count),
                    maximumUpdateCount: count == 0 ? 1 : (count - 1) / maximumPageByteCount + 1)) {
                        (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
                var offset = 0
                while offset < bytes.count {
                    do { try work.checkCancellation() }
                    catch {
                        cancellation = error
                        throw .backendUpdateFailed(reason: "Source admission cancelled")
                    }
                    let end = offset + min(page, bytes.count - offset)
                    try lease.update(Array(bytes[offset..<end]))
                    offset = end
                }
            }
        } catch {
            if let cancellation { throw cancellation }
            throw error
        }
        try work.checkCancellation()
        guard result.digest == binding.reference.digest else { throw SPICEExactSourceError.sourceDrift(binding.key) }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SPICEExactSourceError.invalidUTF8(binding.key)
        }
        return Self(binding: binding, bytes: bytes, text: text)
    }

    private init(binding: SPICEExactSourceBinding, bytes: Data,
                 text: SPICEAccountedText, byteReservation: SPICESourceStorageReservation) {
        self.binding = binding; self.bytes = bytes; self.text = text.text
        self.byteReservation = byteReservation; self.accountedText = text
    }

    /// Verifies the same borrowed bytes, reserving every owned copy and hash chunk first.
    public static func admit(binding: SPICEExactSourceBinding, bytes: borrowing Span<UInt8>,
                             resources: any SPICESourceResourceAccounting,
                             maximumPageByteCount: UInt64) throws -> Self {
        guard !binding.key.isEmpty else { throw SPICEExactSourceError.invalidSourceKey }
        guard maximumPageByteCount > 0, let page = Int(exactly: maximumPageByteCount) else {
            throw SPICEExactSourceError.invalidPolicy
        }
        guard binding.reference.digest.algorithm == .sha256 else { throw SPICEExactSourceError.unsupportedDigest(binding.key) }
        guard UInt64(bytes.count) == binding.reference.byteCount else { throw SPICEExactSourceError.sourceDrift(binding.key) }
        try resources.checkCancellation()
        try resources.charge(.sourceBytes, units: UInt64(bytes.count))
        let rawReservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(bytes.count))
        let hashCapacity = Swift.min(page, bytes.count)
        let hashReservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(hashCapacity))
        let digestReservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 64)
        defer { withExtendedLifetime((hashReservation, digestReservation)) {} }
        return try bytes.withUnsafeBufferPointer { buffer in
            try resources.charge(.projectedBytes, units: UInt64(buffer.count))
            var ownedBytes = Data(); ownedBytes.reserveCapacity(buffer.count)
            var copyOffset = 0
            while copyOffset < buffer.count {
                try resources.checkCancellation()
                let amount = Swift.min(page, buffer.count - copyOffset)
                // Borrowed pointer never escapes; Data owns each copied chunk.
                ownedBytes.append(buffer.baseAddress!.advanced(by: copyOffset), count: amount)
                copyOffset += amount
            }
            var resourceFailure: (any Error)?
            let result: ContentDigestResult
            do {
                result = try SHA256ContentDigester().digest(using: .sha256,
                    limits: ContentDigestSessionLimits(maximumChunkByteCount: maximumPageByteCount,
                        maximumTotalByteCount: Swift.max(1, UInt64(buffer.count)),
                        maximumUpdateCount: buffer.isEmpty ? 1 : (UInt64(buffer.count) - 1) / maximumPageByteCount + 1)) {
                            (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
                    var offset = 0
                    while offset < buffer.count {
                        let amount = Swift.min(page, buffer.count - offset)
                        do {
                            try resources.checkCancellation()
                            try resources.chargeHashedBytes(UInt64(amount))
                            try resources.charge(.projectedBytes, units: UInt64(amount))
                        } catch {
                            resourceFailure = error
                            throw .backendUpdateFailed(reason: "Source accounting refused")
                        }
                        let chunk = Array(UnsafeBufferPointer(start: buffer.baseAddress!.advanced(by: offset), count: amount))
                        try lease.update(chunk)
                        offset += amount
                    }
                }
            } catch {
                if let resourceFailure { throw resourceFailure }
                throw error
            }
            try resources.checkCancellation()
            guard result.totalByteCount == binding.reference.byteCount,
                  result.digest == binding.reference.digest else { throw SPICEExactSourceError.sourceDrift(binding.key) }
            let ownedText: SPICEAccountedText
            do {
                ownedText = try SPICEAccountedText.admit(bytes: bytes, resources: resources, maximumChunkByteCount: maximumPageByteCount)
            } catch SPICEBoundedSourceError.invalidUTF8 { throw SPICEExactSourceError.invalidUTF8(binding.key) }
            try resources.checkCancellation()
            return Self(binding: binding, bytes: ownedBytes, text: ownedText, byteReservation: rawReservation)
        }
    }

    /// Returns an accounted full-source occurrence only under its exact complete binding.
    public func document(expectedBinding: SPICEExactSourceBinding, occurrenceID: SPICEParseOccurrenceID,
                         resolvedPath: String? = nil) throws -> SPICESourceDocument {
        guard binding == expectedBinding else { throw SPICEExactSourceError.sourceDrift(expectedBinding.key) }
        guard let accountedText, isInvocationAccounted else { throw SPICEBoundedSourceError.unaccountedSource }
        return try SPICESourceDocument(accountedText: accountedText, sourceKey: binding.key,
            occurrenceID: occurrenceID, resolvedPath: resolvedPath, retaining: self)
    }
}
