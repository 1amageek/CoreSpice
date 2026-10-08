import Foundation

/// Reads at most the admitted bytes through bounded pages and propagates checked close failures.
public protocol SPICESourceReading: Sendable {
    func read(at path: String, maximumByteCount: UInt64, maximumPageByteCount: UInt64) throws -> Data
}
