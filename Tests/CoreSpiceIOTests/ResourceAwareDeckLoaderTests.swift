import CoreSpiceIO
import CoreSpiceParsedIR
import Foundation
import Synchronization
import Testing

@Suite("Resource-aware local deck intake", .timeLimit(.minutes(1)))
struct ResourceAwareDeckLoaderTests {
    private enum Refusal: Error { case work, hash, storage }
    private final class Resources: SPICESourceResourceAccounting {
        private struct State {
            var work: UInt64 = 0
            var hash: UInt64 = 0
            var live: UInt64 = 0
            var temporary: UInt64 = 0
        }
        private let state = Mutex(State())
        let workLimit: UInt64, hashLimit: UInt64, liveLimit: UInt64, temporaryLimit: UInt64
        init(work: UInt64 = .max, hash: UInt64 = .max, live: UInt64 = .max, temporary: UInt64 = .max) {
            workLimit = work; hashLimit = hash; liveLimit = live; temporaryLimit = temporary
        }
        func checkCancellation() throws { try Task.checkCancellation() }
        func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                guard units <= workLimit - value.work else { throw Refusal.work }; value.work += units
            }
        }
        func chargeHashedBytes(_ bytes: UInt64) throws {
            try checkCancellation()
            try state.withLock { value in
                guard bytes <= hashLimit - value.hash else { throw Refusal.hash }; value.hash += bytes
            }
        }
        func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
            try checkCancellation()
            try state.withLock { value in
                if kind == .liveOwnedBytes {
                    guard byteCount <= liveLimit - value.live else { throw Refusal.storage }; value.live += byteCount
                } else {
                    guard byteCount <= temporaryLimit - value.temporary else { throw Refusal.storage }; value.temporary += byteCount
                }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                }
            }
        }
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
    }
    private final class Reader: SPICESourceReading {
        private let state = Mutex<[String]>([])
        var paths: [String] { state.withLock { $0 } }
        func read(at path: String, maximumByteCount: UInt64, maximumPageByteCount: UInt64) throws -> Data {
            state.withLock { $0.append(path) }
            return try LocalSPICESourceReader().read(at: path, maximumByteCount: maximumByteCount,
                maximumPageByteCount: maximumPageByteCount)
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accounted-deck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Accounted source fixture cleanup failed: \(error)") }
    }
    private var capturePolicy: SPICESourceCapturePolicy {
        get throws { try .init(maximumTotalByteCount: 1024 * 1024, maximumSourceCount: 32, maximumPageByteCount: 4096) }
    }

    @Test(arguments: ["work", "hash", "live", "temporary"])
    func initialAdmissionRefusesBeforeContentReadAndRefunds(resource: String) async throws {
        let directory = try directory(); defer { remove(directory) }
        let path = directory.appendingPathComponent("root.cir")
        try "Pre-read refusal\nR1 out 0 1k\n.op\n.end\n".write(to: path, atomically: true, encoding: .utf8)
        let resources = Resources(work: resource == "work" ? 1 : .max, hash: resource == "hash" ? 1 : .max,
            live: resource == "live" ? 1 : .max, temporary: resource == "temporary" ? 1 : .max)
        let reader = Reader()
        do {
            _ = try await SPICEDeckLoader.loadFile(at: path.path, capturePolicy: capturePolicy,
                resources: resources, sourceReader: reader)
            Issue.record("Profile source intake ignored pre-read \(resource) admission")
        } catch is Refusal {}
        #expect(reader.paths.isEmpty)
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func nestedIncludesAndLibrarySelectionUseOwnedGrammarAndRetainLeases() async throws {
        let directory = try directory(); defer { remove(directory) }
        let root = directory.appendingPathComponent("root.cir")
        let child = directory.appendingPathComponent("child.inc")
        let library = directory.appendingPathComponent("models.lib")
        try "Owned include graph\n.include 'child.inc'\nI1 out 0 -.001\n.op\n.end\n".write(to: root, atomically: true, encoding: .utf8)
        try ".lib 'models.lib' tt\nR1 out 0 sheet\n".write(to: child, atomically: true, encoding: .utf8)
        try ".lib ss\n.model skipped R r=2k\n.endl\n.lib tt\n.model sheet R r=1k\n.endl\n".write(to: library, atomically: true, encoding: .utf8)
        let resources = Resources(), reader = Reader()
        var loaded: LoadedSPICEDeck? = try await SPICEDeckLoader.loadFile(at: root.path,
            capturePolicy: capturePolicy, resources: resources, sourceReader: reader)
        #expect(Set(try #require(loaded).netlist.components.map(\.name)) == ["r1", "i1"])
        #expect(try #require(loaded).netlist.models.map(\.name) == ["sheet"])
        #expect(reader.paths.count == 3)
        #expect(try #require(loaded).netlist.models.first?.origin?.captureID == library.path)
        #expect(resources.live > 0 && resources.temporary == 0)
        var copy = loaded
        loaded = nil
        #expect(copy?.captures.count == 3 && resources.live > 0)
        withExtendedLifetime(copy) {}
        copy = nil
        #expect(resources.live == 0 && resources.temporary == 0)
    }

    @Test func parseFailureReleasesAlreadyReadRootAndSourceReservations() async throws {
        let directory = try directory(); defer { remove(directory) }
        let root = directory.appendingPathComponent("root.cir")
        try "Missing active child\n.include 'missing.inc'\n.op\n.end\n".write(to: root, atomically: true, encoding: .utf8)
        let resources = Resources(), reader = Reader()
        do {
            _ = try await SPICEDeckLoader.loadFile(at: root.path, capturePolicy: capturePolicy,
                resources: resources, sourceReader: reader)
            Issue.record("Missing active include was accepted")
        } catch { #expect(!(error is CancellationError)) }
        #expect(reader.paths.count == 1)
        #expect(resources.live == 0 && resources.temporary == 0)
    }
}
