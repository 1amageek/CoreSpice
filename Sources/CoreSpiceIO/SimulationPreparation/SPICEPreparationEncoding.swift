import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceParsedIR

/// Length-framed versioned semantic encoding with admission before every byte construction.
package struct SPICEPreparationEncoding {
    private var bytes: [UInt8] = []
    private let resources: any SPICESourceResourceAccounting
    private let limit: Int
    private let reservation: SPICESourceStorageReservation?
    private let countOnly: Bool
    private var byteCount = 0
    package init(domain: String, maximumBytes: UInt64, resources: any SPICESourceResourceAccounting) throws {
        try self.init(domain: domain, maximumBytes: maximumBytes, resources: resources, countOnly: false)
    }
    private init(domain: String, maximumBytes: UInt64, resources: any SPICESourceResourceAccounting,
                 countOnly: Bool) throws {
        guard let count = Int(exactly: maximumBytes), count > 0 else { throw SPICESourceStorageError.arithmeticOverflow }
        self.resources = resources; limit = count; self.countOnly = countOnly
        if countOnly { reservation = nil }
        else {
            reservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: maximumBytes)
            bytes.reserveCapacity(count)
        }
        try field(domain)
    }
    /// Replays only immutable framing, never expression evaluation or random draws.
    package static func digest(domain: String, maximumBytes: UInt64,
        resources: any SPICESourceResourceAccounting,
        encode: (inout SPICEPreparationEncoding) throws -> Void) throws -> ContentDigest {
        var preflight = try Self(domain: domain, maximumBytes: maximumBytes, resources: resources, countOnly: true)
        try encode(&preflight)
        var emission = try Self(domain: domain, maximumBytes: UInt64(preflight.byteCount), resources: resources)
        try encode(&emission)
        guard emission.byteCount == preflight.byteCount else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Semantic encoding changed after preflight")
        }
        return try emission.digest()
    }
    package mutating func field(_ text: String) throws {
        let count = text.utf8.count
        guard count <= limit - byteCount, limit - byteCount - count >= 8 else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Semantic encoding capacity")
        }
        try integer(UInt64(count))
        try resources.charge(.projectedBytes, units: UInt64(count))
        for (index, byte) in text.utf8.enumerated() {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            if !countOnly { bytes.append(byte) }
        }
        byteCount += count
    }
    package mutating func integer(_ value: UInt64) throws {
        guard limit - byteCount >= 8 else { throw SPICESourceStorageError.arithmeticOverflow }
        try resources.checkCancellation(); try resources.charge(.projectedBytes, units: 8)
        if !countOnly {
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        byteCount += 8
    }
    package mutating func number(_ value: Double) throws {
        guard value.isFinite else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Nonfinite configuration") }
        try integer(value == 0 ? 0 : value.bitPattern)
    }
    package func digest() throws -> ContentDigest {
        guard !countOnly, bytes.count == byteCount else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Semantic encoding incomplete")
        }
        defer { withExtendedLifetime(reservation) {} }
        try resources.checkCancellation(); try resources.chargeHashedBytes(UInt64(bytes.count))
        return try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(max(1, bytes.count)),
                          maximumTotalByteCount: UInt64(max(1, bytes.count)), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }.digest
    }
}
