import CoreSpiceParsedIR
import CoreSpiceParser

/// String-keyed logical entry capacity with reserved shared-snapshot mutation.
struct SPICEAccountedMap<Value: Sendable>: Sendable {
    private var values: [String: Value] = [:]
    private var reservation: SPICESourceStorageReservation?
    private var identity = Identity()
    private(set) var managedCapacity = 0
    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }

    func value(for key: String, resources: any SPICESourceResourceAccounting) throws -> Value? {
        try Self.checkKey(key, resources: resources)
        return values[key]
    }

    mutating func set(_ value: Value, for key: String,
                      resources: any SPICESourceResourceAccounting) throws {
        try Self.checkKey(key, resources: resources)
        let additional = values[key] == nil ? 1 : 0
        let (count, countOverflow) = values.count.addingReportingOverflow(additional)
        guard !countOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
        try resources.charge(.retainedElements, units: 1)
        if count > managedCapacity {
            let (doubled, overflow) = managedCapacity.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
            try migrate(to: Swift.max(count, doubled), resources: resources)
        } else if !isKnownUniquelyReferenced(&identity) {
            try migrate(to: managedCapacity, resources: resources)
        }
        values[key] = value
    }

    mutating func removeValue(for key: String, resources: any SPICESourceResourceAccounting) throws {
        try Self.checkKey(key, resources: resources)
        guard values[key] != nil else { return }
        if !isKnownUniquelyReferenced(&identity) { try migrate(to: managedCapacity, resources: resources) }
        values.removeValue(forKey: key)
    }

    func forEach(resources: any SPICESourceResourceAccounting,
                 _ body: (String, Value) throws -> Void) throws {
        for (key, value) in values {
            try resources.checkCancellation()
            try resources.charge(.retainedElements, units: 1)
            try body(key, value)
        }
    }

    /// Copies entries under a separate lease; the returned dictionary is retained by storage.
    func ownedDictionary(storage: inout SPICEParseStorage) throws -> [String: Value] {
        let resources = storage.resources
        let receipt = try SPICESourceCapacity.reserve(of: (String, Value).self,
            capacity: count, kind: .liveOwnedBytes, resources: resources)
        try resources.charge(.projectedBytes, units: receipt.byteCount)
        var result = Dictionary<String, Value>(minimumCapacity: count)
        for (key, value) in values {
            try Self.checkKey(key, resources: resources)
            try resources.charge(.retainedElements, units: 1)
            result[key] = value
        }
        try resources.checkCancellation()
        try storage.retain(result, reservation: receipt)
        return result
    }

    mutating func removeAll() {
        values = [:]; reservation = nil; identity = Identity(); managedCapacity = 0
    }

    private mutating func migrate(to capacity: Int, resources: any SPICESourceResourceAccounting) throws {
        let receipt = try SPICESourceCapacity.reserve(of: (String, Value).self,
            capacity: capacity, kind: .liveOwnedBytes, resources: resources)
        try resources.charge(.projectedBytes, units: receipt.byteCount)
        var result = Dictionary<String, Value>(minimumCapacity: capacity)
        for (key, value) in values {
            try Self.checkKey(key, resources: resources)
            try resources.charge(.retainedElements, units: 1)
            result[key] = value
        }
        try resources.checkCancellation()
        values = result; reservation = receipt; identity = Identity(); managedCapacity = capacity
    }

    private static func checkKey(_ key: String, resources: any SPICESourceResourceAccounting) throws {
        try resources.checkCancellation()
        try resources.charge(.lexicalBytes, units: UInt64(key.utf8.count))
        var index = 0
        for byte in key.utf8 {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            guard byte < 128 else {
                throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode map keys")
            }
            index += 1
        }
    }

    private final class Identity: Sendable {}
}
