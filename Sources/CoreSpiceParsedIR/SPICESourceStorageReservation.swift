/// Copies retain one release owner; a receipt is not source or parse-result authority.
public struct SPICESourceStorageReservation: Sendable {
    public let kind: SPICESourceStorageKind
    public let byteCount: UInt64
    private let owner: Owner

    public init(kind: SPICESourceStorageKind, byteCount: UInt64,
                release: @escaping @Sendable () -> Void) {
        self.kind = kind
        self.byteCount = byteCount
        owner = Owner(release: release)
    }

    private final class Owner: Sendable {
        let release: @Sendable () -> Void
        init(release: @escaping @Sendable () -> Void) { self.release = release }
        deinit { release() }
    }
}
