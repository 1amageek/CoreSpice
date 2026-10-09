/// Snapshot-local indices; the snapshot validates each referenced table entry.
public struct MOSSymbolID: Sendable, Hashable { public let rawValue: UInt32; public init(_ rawValue: UInt32) { self.rawValue = rawValue } }
