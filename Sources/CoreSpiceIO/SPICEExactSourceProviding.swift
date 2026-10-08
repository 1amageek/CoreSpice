import CoreSpiceParsedIR

/// Supplies checked immutable owners for exact bindings; it has no implicit path search authority.
public protocol SPICEExactSourceProviding: Sendable {
    func source(for binding: SPICEExactSourceBinding,
                work: any SPICESourceWorkAccounting,
                maximumPageByteCount: UInt64) async throws -> SPICECheckedSource
}
