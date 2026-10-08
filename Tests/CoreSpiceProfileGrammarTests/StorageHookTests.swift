import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Bounded grammar storage hooks")
struct StorageHookTests {
    @Test func exactOwnerMetadataIsAdmittedBeforeExistentialPublication() throws {
        let payloadMetadata = UInt64(MemoryLayout<(Int, SPICESourceStorageReservation?, SPICESourceStorageReservation)>.stride)
        let refused = GrammarTestResources(liveLimit: payloadMetadata - 1)
        var rejected = SPICEParseStorage(resources: refused)
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) { try rejected.hold(13) }
        #expect(refused.used(.liveOwnedBytes) == 0)
        let resources = GrammarTestResources()
        var storage = SPICEParseStorage(resources: resources)
        try storage.hold(13)
        #expect(resources.sawReservation(.liveOwnedBytes, byteCount: payloadMetadata))
        var owner: (any Sendable)? = try storage.immutableOwner()
        let scopeMetadata = UInt64(MemoryLayout<(SPICEParseStorage, SPICESourceStorageReservation?, SPICESourceStorageReservation)>.stride)
        #expect(resources.sawReservation(.liveOwnedBytes, byteCount: scopeMetadata))
        let live = resources.used(.liveOwnedBytes)
        storage = SPICEParseStorage(resources: resources)
        var copy = owner
        owner = nil
        withExtendedLifetime(copy) { #expect(resources.used(.liveOwnedBytes) == live) }
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func sameCapacityMapWritesOwnSeparateSnapshots() throws {
        let resources = GrammarTestResources()
        var original: SPICEAccountedMap<Int>? = SPICEAccountedMap()
        for index in 0..<3 { try original?.set(index, for: "key\(index)", resources: resources) }
        #expect(original?.managedCapacity == 4)
        let one = resources.used(.liveOwnedBytes)
        var appended = original
        var replaced = original
        try appended?.set(3, for: "key3", resources: resources)
        try replaced?.set(9, for: "key0", resources: resources)
        #expect(resources.used(.liveOwnedBytes) == 3 * one)
        #expect(try original?.value(for: "key3", resources: resources) == nil)
        #expect(try original?.value(for: "key0", resources: resources) == 0)
        #expect(try appended?.value(for: "key3", resources: resources) == 3)
        #expect(try replaced?.value(for: "key0", resources: resources) == 9)
        original = nil
        #expect(resources.used(.liveOwnedBytes) == 2 * one)
        appended = nil; replaced = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func mapCloneQuotaRefusalPreservesOriginalAndCopiedEntries() throws {
        let bytes = UInt64(MemoryLayout<(String, Int)>.stride * 4)
        let resources = GrammarTestResources(liveLimit: bytes + bytes / 2)
        var original = SPICEAccountedMap<Int>()
        for index in 0..<3 { try original.set(index, for: "key\(index)", resources: resources) }
        var copy = original
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) {
            try copy.set(7, for: "key0", resources: resources)
        }
        #expect(try original.value(for: "key0", resources: resources) == 0)
        #expect(try copy.value(for: "key0", resources: resources) == 0)
        #expect(copy.managedCapacity == 4)
        #expect(resources.used(.liveOwnedBytes) == bytes)
        copy.removeAll(); original.removeAll()
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func mapGrowthAndRemovalRefundOldCapacityAtItsFinalOwner() throws {
        let resources = GrammarTestResources()
        var original = SPICEAccountedMap<Int>()
        try original.set(1, for: "one", resources: resources)
        let first = resources.used(.liveOwnedBytes)
        var copy = original
        try copy.set(2, for: "two", resources: resources)
        #expect(copy.managedCapacity == 2)
        #expect(resources.used(.liveOwnedBytes) == first * 3)
        original.removeAll()
        #expect(resources.used(.liveOwnedBytes) == first * 2)
        var snapshot = copy
        try copy.removeValue(for: "one", resources: resources)
        #expect(copy.count == 1)
        #expect(snapshot.count == 2)
        #expect(resources.used(.liveOwnedBytes) == first * 4)
        snapshot.removeAll(); copy.removeAll()
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func actualTextArrayAndPayloadOwnersSurviveScopeCopies() throws {
        let resources = GrammarTestResources()
        var storage: SPICEParseStorage? = SPICEParseStorage(resources: resources)
        #expect(try storage?.copyText("owned payload") == "owned payload")
        let beforePayload = resources.used(.liveOwnedBytes)
        var receipt: SPICESourceStorageReservation? = try #require(storage).reservePayload(of: Double.self)
        try storage?.retain(3.5, reservation: #require(receipt))
        receipt = nil
        let payloadMetadata = UInt64(MemoryLayout<(Double, SPICESourceStorageReservation?, SPICESourceStorageReservation)>.stride)
        #expect(resources.used(.liveOwnedBytes) >= beforePayload + 8 + payloadMetadata)
        var builder = SPICEAccountedCollection<Int>(storageKind: .temporaryBytes)
        try builder.append(5, resources: resources)
        try builder.append(8, resources: resources)
        #expect(try storage?.ownArray(builder) == [5, 8])
        builder.removeAll()
        #expect(resources.used(.temporaryBytes) == 0)
        let live = resources.used(.liveOwnedBytes)
        var copy = storage
        storage = nil
        #expect(resources.used(.liveOwnedBytes) == live)
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func ownedDictionaryIsAnIndependentActualPayloadCopy() throws {
        let resources = GrammarTestResources()
        var map = SPICEAccountedMap<Int>()
        try map.set(1, for: "first", resources: resources)
        var storage = SPICEParseStorage(resources: resources)
        var dictionary: [String: Int]? = try map.ownedDictionary(storage: &storage)
        #expect(dictionary?["first"] == 1)
        try map.set(2, for: "first", resources: resources)
        #expect(dictionary?["first"] == 1)
        map.removeAll()
        #expect(resources.used(.liveOwnedBytes) > 0)
        var copy: SPICEParseStorage? = storage
        storage = SPICEParseStorage(resources: resources)
        dictionary = nil
        #expect(resources.used(.liveOwnedBytes) > 0)
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func hookCancellationUnicodeAndCapacityRefuseBeforeStorage() throws {
        let resources = GrammarTestResources()
        var map = SPICEAccountedMap<Int>()
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode map keys")) {
            try map.set(1, for: "\u{00E9}", resources: resources)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        resources.setCancelled(true)
        #expect(throws: GrammarTestError.cancelled) { try map.set(1, for: "key", resources: resources) }
        #expect(resources.used(.liveOwnedBytes) == 0)
        let refused = GrammarTestResources(liveLimit: 0)
        var storage = SPICEParseStorage(resources: refused)
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) { try storage.copyArray([1, 2]) }
        #expect(refused.used(.liveOwnedBytes) == 0)
    }
}
