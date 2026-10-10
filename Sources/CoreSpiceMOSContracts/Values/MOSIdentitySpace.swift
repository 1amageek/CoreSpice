/// Process-local immutable identity for snapshot-local IDs; never a persistent digest.
public final class MOSIdentitySpace: Sendable, Hashable {
    package init() {}
    public func sameStorage(as other: MOSIdentitySpace) -> Bool { self === other }
    public static func == (lhs: MOSIdentitySpace, rhs: MOSIdentitySpace) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
