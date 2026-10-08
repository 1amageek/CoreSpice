/// Checked concrete logical capacity shared by source and parser owners.
public enum SPICESourceCapacity {
    public static func byteCount<Element>(of: Element.Type, capacity: Int) throws -> UInt64 {
        guard capacity >= 0 else { throw SPICESourceStorageError.invalidCapacity }
        let (bytes, overflow) = UInt64(capacity).multipliedReportingOverflow(by: UInt64(MemoryLayout<Element>.stride))
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        return bytes
    }

    public static func reserve<Element>(of: Element.Type, capacity: Int,
        kind: SPICESourceStorageKind, resources: any SPICESourceResourceAccounting)
        throws -> SPICESourceStorageReservation {
        try resources.checkCancellation()
        return try resources.reserveStorage(kind: kind, byteCount: byteCount(of: Element.self, capacity: capacity))
    }
}
