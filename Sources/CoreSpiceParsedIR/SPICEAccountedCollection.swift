/// Accounted slot capacity. Shared snapshots clone before every write, including spare-capacity writes.
public struct SPICEAccountedCollection<Element: Sendable>: RandomAccessCollection, Sendable {
    public typealias Index = Int
    public typealias Indices = Range<Int>
    private var slots: [Element?] = []
    private var reservation: SPICESourceStorageReservation?
    private var identity = Identity()
    public let storageKind: SPICESourceStorageKind
    public private(set) var endIndex = 0
    public var startIndex: Int { 0 }
    public var indices: Range<Int> { 0..<endIndex }
    public var managedCapacity: Int { slots.count }

    public init(storageKind: SPICESourceStorageKind) { self.storageKind = storageKind }
    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < endIndex)
        guard let value = slots[index] else { preconditionFailure("Uninitialized accounted slot") }
        return value
    }
    public func index(after index: Int) -> Int { index + 1 }
    public func index(before index: Int) -> Int { index - 1 }

    public mutating func reserveCapacity(_ capacity: Int, resources: any SPICESourceResourceAccounting) throws {
        guard capacity >= 0 else { throw SPICESourceStorageError.invalidCapacity }
        try resources.checkCancellation()
        if capacity > slots.count { try migrate(to: capacity, resources: resources) }
    }

    public mutating func append(_ value: Element, resources: any SPICESourceResourceAccounting) throws {
        try resources.checkCancellation()
        try resources.charge(.retainedElements, units: 1)
        if endIndex == slots.count {
            let (next, overflow) = slots.count.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
            try migrate(to: Swift.max(1, next), resources: resources)
        } else if !isKnownUniquelyReferenced(&identity) {
            try migrate(to: slots.count, resources: resources)
        }
        slots[endIndex] = value
        endIndex += 1
    }

    public mutating func replace(at index: Int, with value: Element,
                                resources: any SPICESourceResourceAccounting) throws {
        guard index >= 0 && index < endIndex else { throw SPICESourceStorageError.indexOutOfBounds }
        try resources.checkCancellation()
        try resources.charge(.retainedElements, units: 1)
        if !isKnownUniquelyReferenced(&identity) { try migrate(to: slots.count, resources: resources) }
        slots[index] = value
    }

    /// Clears trailing elements without shrinking reserved capacity. Failed admission preserves every snapshot.
    public mutating func truncate(to newEndIndex: Int,
                                 resources: any SPICESourceResourceAccounting) throws {
        guard newEndIndex >= 0 && newEndIndex <= endIndex else {
            throw SPICESourceStorageError.indexOutOfBounds
        }
        try resources.checkCancellation()
        guard newEndIndex != endIndex else { return }
        var remaining = endIndex - newEndIndex
        while remaining > 0 {
            try resources.checkCancellation()
            let chunk = Swift.min(256, remaining)
            try resources.charge(.retainedElements, units: UInt64(chunk))
            remaining -= chunk
        }
        if !isKnownUniquelyReferenced(&identity) {
            try migrate(to: slots.count, resources: resources)
        }
        // All fallible admission precedes this commit; private unique slots cannot trigger an unreserved COW copy.
        for index in newEndIndex..<endIndex { slots[index] = nil }
        endIndex = newEndIndex
    }

    public mutating func removeAll() {
        slots = []; reservation = nil; endIndex = 0; identity = Identity()
    }

    private mutating func migrate(to capacity: Int, resources: any SPICESourceResourceAccounting) throws {
        let nextReservation = try SPICESourceCapacity.reserve(of: Optional<Element>.self,
            capacity: capacity, kind: storageKind, resources: resources)
        try resources.charge(.retainedElements, units: UInt64(capacity))
        var next = [Element?](repeating: nil, count: capacity)
        for index in 0..<endIndex {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            next[index] = slots[index]
        }
        try resources.checkCancellation()
        slots = next; reservation = nextReservation; identity = Identity()
    }

    private final class Identity: Sendable {}
}
