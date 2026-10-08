import CoreSpiceParsedIR
import Synchronization

/// One synchronized invocation budget shared by nested parsing and immutable source intake.
public final class SPICEBoundedSourceWork: SPICESourceWorkAccounting {
    private let limits: SPICESourceWorkLimits
    private let consumed = Mutex<[SPICESourceWorkKind: UInt64]>([:])
    private let upstream: (any SPICESourceWorkAccounting)?

    public init(limits: SPICESourceWorkLimits, upstream: (any SPICESourceWorkAccounting)? = nil) throws {
        guard SPICESourceWorkKind.allCases.allSatisfy({ (limits.limits[$0] ?? 0) > 0 }) else {
            throw SPICEExactSourceError.invalidPolicy
        }
        self.limits = limits
        self.upstream = upstream
    }

    public func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        try checkCancellation()
        try consumed.withLock { state in
            let current = state[kind] ?? 0
            guard let limit = limits.limits[kind], current <= limit, units <= limit - current else {
                throw SPICEExactSourceError.workLimit(kind)
            }
            state[kind] = current + units
        }
        try upstream?.charge(kind, units: units)
    }

    public func checkCancellation() throws {
        try Task.checkCancellation()
        try upstream?.checkCancellation()
    }

    public var consumption: [SPICESourceWorkKind: UInt64] { consumed.withLock { $0 } }
}
