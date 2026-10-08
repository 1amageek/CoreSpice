import CoreSpiceParsedIR

/// Ordinary dictionaries and bounded COW entry storage share parser call sites.
struct SPICEParserMap<Value: Sendable>: Sendable {
    private let resources: (any SPICESourceResourceAccounting)?
    private var legacy: [String: Value] = [:]
    private var owned = SPICEAccountedMap<Value>()
    init(resources: (any SPICESourceResourceAccounting)? = nil) { self.resources = resources }
    var count: Int { resources == nil ? legacy.count : owned.count }
    var isEmpty: Bool { count == 0 }
    subscript(key: String) -> Value? {
        get throws {
            if let resources { return try owned.value(for: key, resources: resources) }
            return legacy[key]
        }
    }
    mutating func set(_ value: Value, for key: String) throws {
        if let resources { try owned.set(value, for: key, resources: resources) }
        else { legacy[key] = value }
    }
    mutating func removeValue(forKey key: String) throws {
        if let resources { try owned.removeValue(for: key, resources: resources) }
        else { legacy.removeValue(forKey: key) }
    }
    func forEach(_ body: (String, Value) throws -> Void) throws {
        if let resources { try owned.forEach(resources: resources, body) }
        else { for (key, value) in legacy { try body(key, value) } }
    }
    func export(storage: inout SPICEParseStorage?) throws -> [String: Value] {
        guard resources != nil else { return legacy }
        guard storage != nil else { preconditionFailure("Bounded map requires owned parse storage") }
        return try owned.ownedDictionary(storage: &storage!)
    }
}
