import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceParsedIR
import Foundation

/// An immutable full-file input owner. Only checked byte admission can construct it.
public struct SPICECheckedSource: Sendable {
    public let binding: SPICEExactSourceBinding
    public let bytes: Data
    let text: String

    private init(binding: SPICEExactSourceBinding, bytes: Data, text: String) {
        self.binding = binding
        self.bytes = bytes
        self.text = text
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
}
