import Foundation
import Darwin
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpice
import Testing

@Suite("OSDI scoped local artifact source", .serialized, .timeLimit(.minutes(1)))
struct OSDILocalArtifactSourceTests {
    @Test func workerAndSourceReadsAcquireFreshRootsAndRetireBeforeTerminalPageReturns() async throws {
        let fixture = try LocalArtifactSourceFixture()
        defer { do { try fixture.remove() } catch { Issue.record("Fixture cleanup failed") } }
        var identities: Set<ArtifactAccessSessionIdentity> = []
        for _ in 0..<3 {
            for (name, reference, expected) in fixture.artifacts {
                #expect(try fixture.openDescriptorCount() == 0)
                let session = try await fixture.source.open(fixture.intent(name: name, reference: reference))
                #expect(identities.insert(session.identity).inserted)
                #expect(session.expectedReference == reference)
                #expect(try fixture.openDescriptorCount() == 2)
                var bytes: [UInt8] = []
                while true {
                    let page = try await session.readPage(.init(offset: UInt64(bytes.count),
                        maximumByteCount: min(4096, reference.byteCount)))
                    page.bytes.withUnsafeBytes { bytes.append(contentsOf: $0) }
                    if page.completion == .complete { break }
                }
                #expect(bytes == expected)
                #expect(try fixture.openDescriptorCount() == 0)
                let first = await session.close(), second = await session.close()
                #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
                let receipt = try await first.wait(), repeated = try await second.wait()
                #expect(receipt == repeated)
                #expect(receipt.sessionIdentity == session.identity && receipt.didReachTerminalPage)
                await #expect(throws: ArtifactAccessError.sessionClosed) {
                    _ = try await session.readPage(.init(offset: reference.byteCount, maximumByteCount: 1))
                }
            }
        }
    }

    @Test func wrongRootOperationDigestAndBoundsPreserveTypedFailureAndCloseEveryDescriptor() async throws {
        let fixture = try LocalArtifactSourceFixture()
        defer { do { try fixture.remove() } catch { Issue.record("Fixture cleanup failed") } }
        let (name, reference, _) = fixture.artifacts[1]
        let wrongRoot = try ArtifactRootID(rawValue: UUID().uuidString)
        await #expect(throws: ArtifactAccessError.rootMismatch(expected: fixture.rootID, actual: wrongRoot)) {
            _ = try await fixture.source.open(fixture.intent(name: name, reference: reference, rootID: wrongRoot))
        }
        await #expect(throws: ArtifactAccessError.unsupportedCapability(reason: "The OSDI artifact source requires an explicit read intent")) {
            _ = try await fixture.source.open(fixture.intent(name: name, reference: reference, operation: .verify))
        }
        await #expect(throws: ArtifactAccessError.totalByteLimitExceeded(limit: reference.byteCount - 1, requested: reference.byteCount)) {
            _ = try await fixture.source.open(fixture.intent(name: name, reference: reference, total: reference.byteCount - 1))
        }
        let session = try await fixture.source.open(fixture.intent(name: name, reference: reference, page: 8))
        await #expect(throws: ArtifactAccessError.pageByteLimitExceeded(limit: 8, requested: 9)) {
            _ = try await session.readPage(.init(offset: 0, maximumByteCount: 9))
        }
        let receipt = try await session.close().wait()
        #expect(!receipt.didReachTerminalPage)
        #expect(try fixture.openDescriptorCount() == 0)
        var changed = fixture.artifacts[1].2
        changed[0] ^= 1
        try Data(changed).write(to: fixture.directory.appendingPathComponent(name))
        do {
            _ = try await fixture.source.open(fixture.intent(name: name, reference: reference))
            Issue.record("Changed source bytes were admitted under the old digest")
        } catch ArtifactAccessError.contentDigestMismatch(let expected, let actual) {
            #expect(expected == reference.digest && actual != expected)
        }
        #expect(try fixture.openDescriptorCount() == 0)
    }

    @Test func cancellationBeforeOpenAndDuringReadStillReleasesRootAndSession() async throws {
        let fixture = try LocalArtifactSourceFixture()
        defer { do { try fixture.remove() } catch { Issue.record("Fixture cleanup failed") } }
        let (name, reference, _) = fixture.artifacts[0]
        let intent = try fixture.intent(name: name, reference: reference)
        let refused = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await fixture.source.open(intent); return false }
            catch ArtifactAccessError.cancelled { return true }
            catch { Issue.record("Unexpected cancelled open failure: \(error)"); return false }
        }.value
        #expect(refused)
        #expect(try fixture.openDescriptorCount() == 0)
        let session = try await fixture.source.open(intent)
        let stopped = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await session.readPage(.init(offset: 0, maximumByteCount: 1)); return false }
            catch ArtifactAccessError.cancelled { return true }
            catch { Issue.record("Unexpected cancelled read failure: \(error)"); return false }
        }.value
        #expect(stopped)
        let receipt = try await session.close().wait()
        #expect(receipt.sessionIdentity == session.identity && !receipt.didReachTerminalPage)
        #expect(try fixture.openDescriptorCount() == 0)
    }

    @Test func concurrentReadCloseAndRepeatedWaitHaveOneTerminationWithoutDrainDeadlock() async throws {
        let fixture = try LocalArtifactSourceFixture()
        defer { do { try fixture.remove() } catch { Issue.record("Fixture cleanup failed") } }
        let (name, reference, _) = fixture.artifacts[0]
        let session = try await fixture.source.open(fixture.intent(name: name, reference: reference))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do { _ = try await session.readPage(.init(offset: 0, maximumByteCount: 1)) }
                catch ArtifactAccessError.sessionClosed {}
            }
            for _ in 0..<8 {
                group.addTask {
                    let receipt = try await session.close().wait()
                    #expect(receipt.sessionIdentity == session.identity && !receipt.didReachTerminalPage)
                }
            }
            try await group.waitForAll()
        }
        #expect(try fixture.openDescriptorCount() == 0)
        let first = await session.close(), second = await session.close()
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
        let firstReceipt = try await first.wait(), secondReceipt = try await second.wait()
        #expect(firstReceipt == secondReceipt)
    }
}

private struct LocalArtifactSourceFixture: Sendable {
    let directory: URL
    let rootID: ArtifactRootID
    let source: SPICEOSDILocalArtifactSource
    let artifacts: [(String, ArtifactReference, [UInt8])]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-local-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            rootID = try ArtifactRootID(rawValue: UUID().uuidString)
            source = try SPICEOSDILocalArtifactSource(rootID: rootID, directoryURL: directory, digester: SHA256ContentDigester())
            let worker = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
            guard !worker.isEmpty, worker.count <= 1024 * 1024 else { throw ArtifactAccessError.resourceUnavailable }
            let model = Data("`include \"constants.vams\"\nmodule test_device(p,n); inout p,n; electrical p,n; analog I(p,n)<+V(p,n); endmodule\n".utf8)
            var admitted: [(String, ArtifactReference, [UInt8])] = []
            for (name, bytes) in [("precision-worker", worker), ("model.va", model)] {
                try bytes.write(to: directory.appendingPathComponent(name))
                let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                    .init(location: ArtifactLocation(workspaceRelativePath: name), role: .input, kind: .model, format: .raw),
                    relativeTo: directory)
                admitted.append((name, reference, Array(bytes)))
            }
            artifacts = admitted
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch let cleanup { throw ArtifactAccessError.cleanupFailed(primary: String(describing: error), closeReason: String(describing: cleanup)) }
            throw error
        }
    }

    func remove() throws { try FileManager.default.removeItem(at: directory) }

    func intent(name: String, reference: ArtifactReference, rootID: ArtifactRootID? = nil,
                operation: ArtifactAccessOperation = .read, total: UInt64? = nil, page: UInt64? = nil) throws -> ArtifactAccessIntent {
        let total = total ?? reference.byteCount
        return try ArtifactAccessIntent(expectedReference: reference,
            availability: .local(artifactID: reference.id, rootID: rootID ?? self.rootID,
                relativePath: ArtifactRelativePath(segments: [name])), operation: operation,
            budget: ArtifactAccessBudget(maximumPageByteCount: page ?? min(4096, total), maximumTotalByteCount: total,
                maximumPageCount: 1024, maximumWorkUnitCount: 2048, maximumDurationNanoseconds: 5_000_000_000))
    }

    /// Match actual file identities, not a path-string projection that can silently miss live descriptors.
    func openDescriptorCount() throws -> Int {
        var owned: Set<ArtifactTestFileIdentity> = []
        for url in [directory] + artifacts.map({ directory.appendingPathComponent($0.0) }) {
            var information = stat()
            let status = url.path.withCString { fstatat(AT_FDCWD, $0, &information, 0) }
            guard status == 0 else {
                throw ArtifactAccessError.metadataFailed(reason: String(cString: strerror(errno)))
            }
            owned.insert(.init(device: information.st_dev, inode: information.st_ino))
        }
        var count = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
            guard let descriptor = Int32(name) else { continue }
            var information = stat()
            if fstat(descriptor, &information) != 0 {
                // Directory enumeration can include its own descriptor, already closed on return.
                if errno == EBADF { continue }
                throw ArtifactAccessError.metadataFailed(reason: String(cString: strerror(errno)))
            }
            if owned.contains(.init(device: information.st_dev, inode: information.st_ino)) { count += 1 }
        }
        return count
    }
}

private struct ArtifactTestFileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}
