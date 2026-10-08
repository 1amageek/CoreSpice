import CoreSpiceParsedIR
import CoreSpiceParser

/// Invocation-local ownership of actual parser payloads and their admitted extents.
struct SPICEParseStorage: Sendable {
    let resources: any SPICESourceResourceAccounting
    private var owners = SPICEAccountedCollection<any Sendable>(storageKind: .liveOwnedBytes)

    init(resources: any SPICESourceResourceAccounting) { self.resources = resources }

    func reservePayload<Payload>(of type: Payload.Type) throws -> SPICESourceStorageReservation {
        try resources.checkCancellation()
        try resources.charge(.retainedElements, units: 1)
        return try SPICESourceCapacity.reserve(of: type, capacity: 1, kind: .liveOwnedBytes, resources: resources)
    }

    mutating func retain<Value: Sendable>(_ value: Value,
        reservation: SPICESourceStorageReservation) throws {
        let metadata = try metadataReservation(of: Value.self)
        try owners.append(OwnedValue(value: value, reservation: reservation,
            metadataReservation: metadata), resources: resources)
    }

    mutating func hold<Owner: Sendable>(_ owner: Owner) throws {
        let metadata = try metadataReservation(of: Owner.self)
        try owners.append(OwnedValue(value: owner, reservation: nil,
            metadataReservation: metadata), resources: resources)
    }

    /// A class reference crosses the existential boundary without an unmetered value box.
    func immutableOwner() throws -> any Sendable {
        let metadata = try metadataReservation(of: Self.self)
        return OwnedValue(value: self, reservation: nil, metadataReservation: metadata)
    }

    mutating func copyText(_ text: String) throws -> String {
        let owner = try SPICEAccountedText.copy(text, resources: resources, maximumChunkByteCount: 256)
        try hold(owner)
        return owner.text
    }

    /// The returned raw array is used while retaining this scope or its immutable copy.
    mutating func ownArray<Element: Sendable>(_ input: SPICEAccountedCollection<Element>) throws -> [Element] {
        let reservation = try SPICESourceCapacity.reserve(of: Element.self, capacity: input.count,
            kind: .liveOwnedBytes, resources: resources)
        try resources.charge(.projectedBytes, units: reservation.byteCount)
        var output: [Element] = []
        output.reserveCapacity(input.count)
        for index in input.indices {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            output.append(input[index])
        }
        try resources.checkCancellation()
        try retain(output, reservation: reservation)
        return output
    }

    /// Reserves a one-shot immutable array copy; the caller's input is already owned.
    mutating func copyArray<Element: Sendable>(_ input: [Element]) throws -> [Element] {
        let reservation = try SPICESourceCapacity.reserve(of: Element.self, capacity: input.count,
            kind: .liveOwnedBytes, resources: resources)
        try resources.charge(.projectedBytes, units: reservation.byteCount)
        var output: [Element] = []
        output.reserveCapacity(input.count)
        for index in input.indices {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            output.append(input[index])
        }
        try resources.checkCancellation()
        try retain(output, reservation: reservation)
        return output
    }

    private func metadataReservation<Value>(of type: Value.Type) throws -> SPICESourceStorageReservation {
        // These are the owner's actual stored fields; allocator/class headers are excluded.
        try SPICESourceCapacity.reserve(of: (Value, SPICESourceStorageReservation?, SPICESourceStorageReservation).self,
            capacity: 1, kind: .liveOwnedBytes, resources: resources)
    }

    private final class OwnedValue<Value: Sendable>: Sendable {
        let value: Value
        let reservation: SPICESourceStorageReservation?
        let metadataReservation: SPICESourceStorageReservation
        init(value: Value, reservation: SPICESourceStorageReservation?, metadataReservation: SPICESourceStorageReservation) {
            self.value = value; self.reservation = reservation; self.metadataReservation = metadataReservation
        }
    }
}
