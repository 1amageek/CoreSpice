import CoreSpiceParsedIR
import Testing

@Suite("Accounted trailing truncation", .timeLimit(.minutes(1)))
struct AccountedCollectionTruncationTests {
    @Test func uniqueTruncationReusesCapacityAndReleasesRemovedPayloads() throws {
        let resources = SourceBoundaryTestResources()
        var values = SPICEAccountedCollection<SPICESourceStorageReservation>(storageKind: .temporaryBytes)
        try values.reserveCapacity(4, resources: resources)
        for _ in 0..<3 {
            try values.append(resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 17), resources: resources)
        }
        let capacityBytes = resources.used(.temporaryBytes)
        let work = resources.work(.retainedElements)
        let releases = resources.releaseCount
        try values.truncate(to: 1, resources: resources)
        #expect(values.count == 1 && values.managedCapacity == 4)
        #expect(resources.work(.retainedElements) == work + 2)
        #expect(resources.used(.temporaryBytes) == capacityBytes)
        #expect(resources.used(.liveOwnedBytes) == 17)
        #expect(resources.releaseCount == releases + 2)
        try values.append(resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 9), resources: resources)
        #expect(values[1].byteCount == 9 && resources.used(.temporaryBytes) == capacityBytes)
        values.removeAll()
        #expect(resources.used(.liveOwnedBytes) == 0 && resources.used(.temporaryBytes) == 0)
    }

    @Test func sharedTruncationClonesOnceAndPreservesTheOriginalSnapshot() throws {
        let resources = SourceBoundaryTestResources()
        var original = SPICEAccountedCollection<Int>(storageKind: .liveOwnedBytes)
        try original.reserveCapacity(4, resources: resources)
        for value in 1...3 { try original.append(value, resources: resources) }
        var copy = original
        let bytes = resources.used(.liveOwnedBytes)
        let work = resources.work(.retainedElements)
        try copy.truncate(to: copy.count, resources: resources)
        #expect(resources.used(.liveOwnedBytes) == bytes && resources.work(.retainedElements) == work)
        try copy.truncate(to: 1, resources: resources)
        #expect(original.count == 3 && original[2] == 3)
        #expect(copy.count == 1 && copy[0] == 1 && copy.managedCapacity == 4)
        #expect(resources.used(.liveOwnedBytes) == 2 * bytes)
        #expect(resources.work(.retainedElements) == work + 2 + 4)
        try copy.append(9, resources: resources)
        #expect(copy[1] == 9 && original[1] == 2)
        #expect(resources.used(.liveOwnedBytes) == 2 * bytes)
        original.removeAll(); copy.removeAll()
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func rangeAndStorageRefusalsPreserveBothSnapshots() throws {
        let bytes = UInt64(4 * MemoryLayout<Int?>.stride)
        let resources = SourceBoundaryTestResources(liveLimit: bytes)
        var original = SPICEAccountedCollection<Int>(storageKind: .liveOwnedBytes)
        try original.reserveCapacity(4, resources: resources)
        for value in 1...3 { try original.append(value, resources: resources) }
        var copy = original
        for invalid in [-1, 4] {
            #expect(throws: SPICESourceStorageError.indexOutOfBounds) {
                try copy.truncate(to: invalid, resources: resources)
            }
        }
        #expect(throws: SourceBoundaryTestError.limit(.liveOwnedBytes)) {
            try copy.truncate(to: 1, resources: resources)
        }
        #expect(copy.count == 3 && original.count == 3 && copy[2] == 3)
        #expect(copy.managedCapacity == 4 && resources.used(.liveOwnedBytes) == bytes)
        copy.removeAll()
        try original.truncate(to: 0, resources: resources)
        #expect(original.isEmpty && original.managedCapacity == 4)
        #expect(resources.used(.liveOwnedBytes) == bytes)
        original.removeAll()
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func workRefusalRefundsAnAdmittedUnpublishedClone() throws {
        let resources = SourceBoundaryTestResources(workLimit: 8)
        var original = SPICEAccountedCollection<Int>(storageKind: .liveOwnedBytes)
        try original.reserveCapacity(4, resources: resources)
        for value in 1...3 { try original.append(value, resources: resources) }
        var copy = original
        let bytes = resources.used(.liveOwnedBytes)
        #expect(throws: SourceBoundaryTestError.workLimit) { try copy.truncate(to: 2, resources: resources) }
        #expect(copy.count == 3 && copy[2] == 3 && original.count == 3)
        #expect(resources.peakLiveBytes == 2 * bytes && resources.used(.liveOwnedBytes) == bytes)
        copy.removeAll(); original.removeAll()
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func cancellationBeforeCommitAndDuringClonePreservesContents() throws {
        for shared in [false, true] {
            let resources = SourceBoundaryTestResources()
            var values = SPICEAccountedCollection<Int>(storageKind: .liveOwnedBytes)
            try values.reserveCapacity(1024, resources: resources)
            for value in 0..<600 { try values.append(value, resources: resources) }
            var snapshot: SPICEAccountedCollection<Int>? = shared ? values : nil
            let bytes = resources.used(.liveOwnedBytes)
            resources.cancelAfterChecks(shared ? 8 : 4)
            #expect(throws: SourceBoundaryTestError.cancelled) {
                try values.truncate(to: shared ? 599 : 0, resources: resources)
            }
            #expect(values.count == 600 && values[599] == 599 && values.managedCapacity == 1024)
            #expect(resources.used(.liveOwnedBytes) == bytes)
            if shared {
                #expect(snapshot?.count == 600 && snapshot?[599] == 599)
                #expect(resources.peakLiveBytes == 2 * bytes)
            } else { #expect(resources.peakLiveBytes == bytes) }
            snapshot = nil; values.removeAll()
            #expect(resources.used(.liveOwnedBytes) == 0)
        }
    }
}
