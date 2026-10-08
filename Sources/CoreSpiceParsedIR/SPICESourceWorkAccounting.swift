/// Synchronous cooperative work boundary, independent of host or PDK policy.
/// Implementations must synchronize shared mutable accounting and throw on exhaustion/cancellation.
public protocol SPICESourceWorkAccounting: Sendable {
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws
    func checkCancellation() throws
}
