import CoreSpiceParsedIR
import Testing

@Suite("Owned source storage capacity")
struct StorageBoundaryTests {
    @Test func trustedReceiptReleasesOnlyAfterItsFinalCopy() throws {
        let resources = SourceBoundaryTestResources()
        var first: SPICESourceStorageReservation? = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 17)
        var second = first
        #expect(resources.used(.liveOwnedBytes) == 17)
        first = nil
        #expect(resources.used(.liveOwnedBytes) == 17)
        withExtendedLifetime(second) {}
        second = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.releaseCount == 1)
    }

    @Test func spareCapacityAppendAndReplaceOwnIndependentSnapshots() throws {
        let resources = SourceBoundaryTestResources()
        let capacityBytes = UInt64(4 * MemoryLayout<Int?>.stride)
        var original: SPICEAccountedCollection<Int>? = .init(storageKind: .liveOwnedBytes)
        try original!.reserveCapacity(4, resources: resources)
        for value in 1...3 { try original!.append(value, resources: resources) }
        var appended = original
        try appended!.append(4, resources: resources)
        #expect(original!.count == 3 && appended!.count == 4)
        #expect(resources.used(.liveOwnedBytes) == 2 * capacityBytes)
        var replaced = original
        try replaced!.replace(at: 1, with: 9, resources: resources)
        #expect(original![1] == 2 && replaced![1] == 9)
        #expect(resources.used(.liveOwnedBytes) == 3 * capacityBytes)
        original = nil
        #expect(resources.used(.liveOwnedBytes) == 2 * capacityBytes)
        withExtendedLifetime((appended, replaced)) {}
        appended = nil; replaced = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func refusedCloneAndGrowthLeaveOriginalContentsAndRefundMigration() throws {
        let capacityBytes = UInt64(4 * MemoryLayout<Int?>.stride)
        let resources = SourceBoundaryTestResources(liveLimit: capacityBytes)
        var original = SPICEAccountedCollection<Int>(storageKind: .liveOwnedBytes)
        try original.reserveCapacity(4, resources: resources)
        for value in 1...3 { try original.append(value, resources: resources) }
        var copy = original
        #expect(throws: SourceBoundaryTestError.limit(.liveOwnedBytes)) { try copy.append(4, resources: resources) }
        #expect(throws: SourceBoundaryTestError.limit(.liveOwnedBytes)) { try copy.replace(at: 0, with: 8, resources: resources) }
        #expect(copy.count == 3 && original.count == 3 && copy[0] == 1)
        #expect(resources.used(.liveOwnedBytes) == capacityBytes)
        copy.removeAll()
        try original.append(4, resources: resources)
        #expect(throws: SourceBoundaryTestError.limit(.liveOwnedBytes)) { try original.append(5, resources: resources) }
        #expect(original.count == 4 && original[3] == 4)
        original.removeAll()
        #expect(resources.used(.liveOwnedBytes) == 0)
        let growing = SourceBoundaryTestResources()
        var values = SPICEAccountedCollection<Int>(storageKind: .liveOwnedBytes)
        try values.append(1, resources: growing); try values.append(2, resources: growing)
        #expect(growing.used(.liveOwnedBytes) == UInt64(2 * MemoryLayout<Int?>.stride))
        #expect(growing.peakLiveBytes == UInt64(3 * MemoryLayout<Int?>.stride))
    }

    @Test func invalidCapacityOverflowAndCancellationPrecedeStorage() throws {
        let resources = SourceBoundaryTestResources()
        #expect(throws: SPICESourceStorageError.invalidCapacity) {
            _ = try SPICESourceCapacity.byteCount(of: Int.self, capacity: -1)
        }
        #expect(throws: SPICESourceStorageError.arithmeticOverflow) {
            _ = try SPICESourceCapacity.byteCount(of: UInt64.self, capacity: Int.max)
        }
        var values = SPICEAccountedCollection<Int>(storageKind: .temporaryBytes)
        resources.setCancelled(true)
        #expect(throws: SourceBoundaryTestError.cancelled) { try values.append(1, resources: resources) }
        #expect(values.isEmpty && resources.used(.temporaryBytes) == 0)
    }
}
