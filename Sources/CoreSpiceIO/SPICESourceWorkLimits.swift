import CoreSpiceParsedIR

/// All dimensions must have positive finite ceilings; the caller chooses operational policy.
public struct SPICESourceWorkLimits: Sendable, Hashable {
    public let limits: [SPICESourceWorkKind: UInt64]
    public init(limits: [SPICESourceWorkKind: UInt64]) { self.limits = limits }
}
