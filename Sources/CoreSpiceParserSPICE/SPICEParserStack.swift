import CoreSpiceParsedIR

/// Parser scratch stack; nil slots release popped values without allocating a new stack.
struct SPICEParserStack<Element: Sendable>: Sendable {
    private var ordinary: [Element] = []
    private var owned = SPICEAccountedCollection<Element?>(storageKind: .temporaryBytes)
    private var ownedCount = 0
    private var isOwned = false
    var count: Int { isOwned ? ownedCount : ordinary.count }
    var isEmpty: Bool { count == 0 }
    var indices: Range<Int> { 0..<count }
    var last: Element? { isEmpty ? nil : self[count - 1] }
    subscript(index: Int) -> Element {
        if isOwned { return owned[index]! }
        return ordinary[index]
    }
    mutating func append(_ value: Element, resources: (any SPICESourceResourceAccounting)?) throws {
        guard let resources else { ordinary.append(value); return }
        isOwned = true
        if ownedCount < owned.count { try owned.replace(at: ownedCount, with: value, resources: resources) }
        else { try owned.append(value, resources: resources) }
        ownedCount += 1
    }
    mutating func replace(at index: Int, with value: Element,
                          resources: (any SPICESourceResourceAccounting)?) throws {
        guard let resources else { ordinary[index] = value; return }
        try owned.replace(at: index, with: value, resources: resources)
    }
    mutating func removeLast(resources: (any SPICESourceResourceAccounting)?) throws -> Element? {
        guard !isEmpty else { return nil }
        guard let resources else { return ordinary.popLast() }
        let value = self[ownedCount - 1]
        try owned.replace(at: ownedCount - 1, with: nil, resources: resources)
        ownedCount -= 1
        return value
    }
    func export(storage: inout SPICEParseStorage?) throws -> [Element] {
        guard let resources = storage?.resources else { return ordinary }
        var builder = SPICEAccountedCollection<Element>(storageKind: .temporaryBytes)
        try builder.reserveCapacity(count, resources: resources)
        for index in indices { try builder.append(self[index], resources: resources) }
        let output = try storage!.ownArray(builder)
        return output
    }
}
