/// Trusted invocation accounting; implementations synchronize shared state.
public protocol SPICESourceResourceAccounting: SPICESourceWorkAccounting {
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation
    func chargeHashedBytes(_ byteCount: UInt64) throws
}
