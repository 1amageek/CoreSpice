import CoreSpiceIO
import Foundation
import Testing

@Suite("SPICE deck loader tests")
struct SPICEDeckLoaderTests {

    @Test("Nested include files are merged and recorded as execution inputs")
    func nestedIncludesAreMergedAndRecorded() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }

        let nestedDirectory = directory.appendingPathComponent("models")
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        let modelURL = nestedDirectory.appendingPathComponent("device.inc")
        try """
        .model dmodel d
        """.write(to: modelURL, atomically: true, encoding: .utf8)

        let componentsURL = directory.appendingPathComponent("components.inc")
        try """
        .include "models/device.inc"
        D1 out 0 dmodel
        R1 in out 1k
        """.write(to: componentsURL, atomically: true, encoding: .utf8)

        let rootURL = directory.appendingPathComponent("root.sp")
        try """
        resolved include deck
        V1 in 0 dc 1
        .include "components.inc"
        .op
        .end
        """.write(to: rootURL, atomically: true, encoding: .utf8)

        let loaded = try await SPICEDeckLoader.loadFile(at: rootURL.path)

        #expect(Set(loaded.netlist.components.map(\.name)) == ["v1", "d1", "r1"])
        #expect(loaded.netlist.models.map(\.name) == ["dmodel"])
        #expect(loaded.inputPaths == [
            rootURL.resolvingSymlinksInPath().path,
            componentsURL.resolvingSymlinksInPath().path,
            modelURL.resolvingSymlinksInPath().path,
        ])
    }

    @Test("A missing include fails before lowering")
    func missingIncludeFails() async throws {
        let directory = try temporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let rootURL = directory.appendingPathComponent("root.sp")
        try """
        missing include deck
        .include "missing.inc"
        .op
        .end
        """.write(to: rootURL, atomically: true, encoding: .utf8)

        await #expect(throws: ParserDiagnostic.self) {
            _ = try await SPICEDeckLoader.loadFile(at: rootURL.path)
        }
    }

    @Test("Blocked execution intent is rejected before simulation")
    func blockedIntentFails() async throws {
        let source = """
        blocked deck
        V1 in 0 dc 1
        R1 in 0 1k
        .alter R1 resistance=2k
        .op
        .end
        """

        do {
            _ = try await SPICEDeckLoader.load(source: source)
            Issue.record("Expected blocked execution intent to fail.")
        } catch let error as SPICEDeckLoadError {
            guard case .blockedExecutionIntent(let items) = error else {
                Issue.record("Unexpected deck load error: \(error)")
                return
            }
            #expect(items.contains { $0.name.hasPrefix("alter:") })
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corespice-deck-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove temporary directory: \(error)")
        }
    }
}
