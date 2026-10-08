import CoreSpiceParsedIR

/// Existing parser arrays use the accounted builder only at the bounded entry.
struct SPICEParserBuffer<Element: Sendable>: RandomAccessCollection, Sendable {
    private let resources: (any SPICESourceResourceAccounting)?
    private var legacy: [Element] = []
    private var owned: SPICEAccountedCollection<Element>?
    init(resources: (any SPICESourceResourceAccounting)? = nil) {
        self.resources = resources
        self.owned = resources == nil ? nil : SPICEAccountedCollection(storageKind: .liveOwnedBytes)
    }
    var startIndex: Int { 0 }
    var endIndex: Int { owned?.count ?? legacy.count }
    subscript(index: Int) -> Element { owned?[index] ?? legacy[index] }
    func index(after index: Int) -> Int { index + 1 }
    func index(before index: Int) -> Int { index - 1 }
    mutating func append(_ value: Element) throws {
        if let resources { try owned!.append(value, resources: resources) }
        else { legacy.append(value) }
    }
    mutating func append<Values: Collection>(contentsOf values: Values) throws where Values.Element == Element {
        for value in values { try resources?.checkCancellation(); try append(value) }
    }
    mutating func export(storage: inout SPICEParseStorage?) throws -> [Element] {
        guard resources != nil else { return legacy }
        guard storage != nil, let owned else { preconditionFailure("Bounded buffer requires owned parse storage") }
        return try storage!.ownArray(owned)
    }
}
