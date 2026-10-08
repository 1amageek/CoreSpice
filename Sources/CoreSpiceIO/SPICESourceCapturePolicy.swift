/// Finite host resource policy for the unique source graph retained by one load.
public struct SPICESourceCapturePolicy: Sendable, Hashable, Codable {
    public let maximumTotalByteCount: UInt64
    public let maximumSourceCount: UInt64
    public let maximumPageByteCount: UInt64

    /// Operational host defaults; these limits do not express physical tolerances.
    public static let hostDefault = Self(totalBytes: 64 * 1024 * 1024, sources: 4096, pageBytes: 64 * 1024)

    public init(maximumTotalByteCount: UInt64, maximumSourceCount: UInt64,
                maximumPageByteCount: UInt64) throws {
        guard maximumTotalByteCount > 0, maximumTotalByteCount <= UInt64(Int.max),
              maximumSourceCount > 0, maximumSourceCount <= UInt64(Int.max),
              maximumPageByteCount > 0, maximumPageByteCount <= maximumTotalByteCount else {
            throw SPICESourceCaptureError.invalidPolicy
        }
        self.init(totalBytes: maximumTotalByteCount, sources: maximumSourceCount, pageBytes: maximumPageByteCount)
    }

    private init(totalBytes: UInt64, sources: UInt64, pageBytes: UInt64) {
        maximumTotalByteCount = totalBytes
        maximumSourceCount = sources
        maximumPageByteCount = pageBytes
    }

    private enum CodingKeys: String, CodingKey { case maximumTotalByteCount, maximumSourceCount, maximumPageByteCount }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumTotalByteCount: values.decode(UInt64.self, forKey: .maximumTotalByteCount),
                      maximumSourceCount: values.decode(UInt64.self, forKey: .maximumSourceCount),
                      maximumPageByteCount: values.decode(UInt64.self, forKey: .maximumPageByteCount))
    }
}
