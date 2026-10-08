import CoreSpiceCompile
import Foundation
import Synchronization
import Testing
@testable import CoreSpiceIO

@Suite("Consumed SPICE source capture")
struct SPICESourceCaptureTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Failed source fixture cleanup: \(error)") }
    }

    private func real(_ value: ParameterValue?) -> Double? {
        guard case .real(let number) = value else { return nil }
        return number
    }

    @Test func nativeCapturedBytesSurviveMutationAndRepeatedPaths() async throws {
        let dir = try directory()
        defer { remove(dir) }
        let file = dir.appendingPathComponent("model.inc")
        let original = ".model sheet R r=100\r\n+ tc1=0.001\r\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let resolver = SPICECapturingFileResolver()
        let first = try await resolver.resolveInclude(path: "model.inc", relativeTo: dir.appendingPathComponent("root.sp").path)
        try ".model sheet R r=900\n".write(to: file, atomically: true, encoding: .utf8)
        let second = try await resolver.resolveInclude(path: "model.inc", relativeTo: dir.appendingPathComponent("root.sp").path)
        try FileManager.default.removeItem(at: file)
        let third = try await resolver.resolveInclude(path: "model.inc", relativeTo: dir.appendingPathComponent("root.sp").path)
        let captures = await resolver.capturedSources()
        #expect(first.captureID == second.captureID)
        #expect(second.text == original)
        #expect(third.text == original)
        #expect(captures.count == 1)
        #expect(captures[0].bytes == Data(original.utf8))
        #expect(captures[0].artifactID.byteCount == UInt64(original.utf8.count))
        #expect(captures[0].artifactID.digest.hexadecimalValue == "1b565d592c16ff91837a66cf29470a922ebb6eae99780dfd87a2b5a41de7094a")
    }

    @Test func suppliedMemorySourceWinsOverExistingDiagnosticFile() async throws {
        let dir = try directory()
        defer { remove(dir) }
        let file = dir.appendingPathComponent("root.sp")
        try "disk source\n.model sheet R r=900\n.end\n".write(to: file, atomically: true, encoding: .utf8)
        let source = "memory source\n.model sheet R r=100\nR1 out 0 sheet\n.end\n"
        let loaded = try await SPICEDeckLoader.load(source: source, fileName: file.path)
        #expect(loaded.captures.count == 1)
        #expect(loaded.captures[0].bytes == Data(source.utf8))
        #expect(loaded.capturePolicy == .hostDefault)
        let origin = try #require(loaded.netlist.models.first?.origin)
        #expect(origin.captureID == loaded.captures[0].captureID)
        #expect(origin.location.line == 2)
    }

    @Test func nestedSearchPathGraphRetainsSelectedDeclarationAndLibraryLines() async throws {
        let dir = try directory()
        defer { remove(dir) }
        let search = dir.appendingPathComponent("search")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        let model = search.appendingPathComponent("models.lib")
        let library = "* header\r\n.lib ff\r\n.model sheet R r=900\r\n.endl\r\n.lib tt\r\n.model sheet R r=100\r\n+ tc1=0.001\r\n.endl\r\n"
        try library.write(to: model, atomically: true, encoding: .utf8)
        try ".lib models.lib tt\n".write(to: search.appendingPathComponent("cell.inc"), atomically: true, encoding: .utf8)
        let source = "source graph\n.include cell.inc\n.include cell.inc\nR1 out 0 sheet\n.end\n"
        let loaded = try await SPICEDeckLoader.load(source: source,
            fileName: dir.appendingPathComponent("root.sp").path, includePaths: [search.path])
        #expect(loaded.captures.count == 3)
        let declaration = try #require(loaded.netlist.models.last)
        #expect(declaration.location?.file == model.path)
        #expect(declaration.location?.line == 6)
        let origin = try #require(declaration.origin)
        #expect(loaded.modelOrigins[origin.declarationID] == origin)
        let ir = try SPICEIO.lower(loaded.netlist)
        let selected = try #require(ir.instances.first?.model)
        #expect(selected.declarationID == origin.declarationID)
        #expect(real(selected.parameters["r"]) == 100)
        #expect(!selected.parameters.keys.contains("declarationID"))
        let capturedLibrary = try #require(loaded.captures.first { $0.resolvedPath == model.path })
        #expect(capturedLibrary.bytes == Data(library.utf8))
    }

    @Test func sameNamedScopedDeclarationsRetainActualSelectedOrigins() async throws {
        let loaded = try await SPICEDeckLoader.load(source: """
        scoped source identity
        .model sheet R r=100
        .subckt cell a
        .model sheet R r=200
        R1 a 0 sheet
        .ends
        R0 out 0 sheet
        X1 out cell
        .end
        """)
        let ir = try SPICEIO.lower(loaded.netlist)
        let outer = try #require(ir.instances.first { $0.name == "r0" }?.model)
        let inner = try #require(ir.instances.first { $0.name == "x1.r1" }?.model)
        #expect(outer.name == inner.name)
        #expect(outer.declarationID != inner.declarationID)
        let outerID = try #require(outer.declarationID)
        let innerID = try #require(inner.declarationID)
        #expect(loaded.modelOrigins[outerID]?.location.line == 2)
        #expect(loaded.modelOrigins[innerID]?.location.line == 4)
        #expect(real(outer.parameters["r"]) == 100)
        #expect(real(inner.parameters["r"]) == 200)
        let uncaptured = try await SPICEIO.parse("uncaptured\n.model sheet R r=100\nR1 out 0 sheet\n.end\n").get()
        #expect(uncaptured.models.first?.origin == nil)
        #expect(try SPICEIO.lower(uncaptured).instances.first?.model?.declarationID == nil)
    }

    @Test func wrongSourceBoundModelIsRejectedDespiteSameNameAndType() async throws {
        let first = try await SPICEDeckLoader.load(source: "first\n.model sheet R r=100\nR1 out 0 sheet\n.end\n")
        let second = try await SPICEDeckLoader.load(source: "second\n.model sheet R r=200\nR1 out 0 sheet\n.end\n")
        let plan = try StandardCompiler().compile(ir: SPICEIO.lower(first.netlist))
        let other = try SPICEIO.lower(second.netlist)
        let instance = try #require(other.instances.first)
        var context = BindingContext(variableMap: plan.topology.variableMap, matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, column in plan.matrixStructure.index(row: row, col: column) })
        let wrong = try ResistorDescriptor().bind(instance: instance, context: &context)
        #expect(throws: PreparedCircuitError.self) { _ = try PreparedCircuit(plan: plan, devices: [wrong]) }
        let correct = try StandardCircuitDeviceBinding().bind(plan: plan, instances: plan.ir.instances)
        #expect(correct.devices.first?.instance.model?.declarationID == plan.ir.instances.first?.model?.declarationID)
    }

    @Test func graphByteAndSourceLimitsAreCheckedAtTheirBoundary() async throws {
        let dir = try directory()
        defer { remove(dir) }
        let file = dir.appendingPathComponent("model.inc")
        let model = ".model sheet R r=100\n"
        try model.write(to: file, atomically: true, encoding: .utf8)
        let source = "bounded graph\n.include model.inc\nR1 out 0 sheet\n.end\n"
        let total = UInt64(source.utf8.count + model.utf8.count)
        let exact = try SPICESourceCapturePolicy(maximumTotalByteCount: total, maximumSourceCount: 2, maximumPageByteCount: 1)
        let loaded = try await SPICEDeckLoader.load(source: source, fileName: dir.appendingPathComponent("root.sp").path,
                                                   capturePolicy: exact)
        #expect(loaded.capturePolicy == exact)
        #expect(loaded.captures.reduce(UInt64(0)) { $0 + $1.artifactID.byteCount } == total)
        let bytesShort = try SPICESourceCapturePolicy(maximumTotalByteCount: total - 1, maximumSourceCount: 2, maximumPageByteCount: 1)
        await #expect(throws: SPICESourceCaptureError.self) {
            _ = try await SPICEDeckLoader.load(source: source, fileName: dir.appendingPathComponent("root.sp").path,
                                               capturePolicy: bytesShort)
        }
        let sourceShort = try SPICESourceCapturePolicy(maximumTotalByteCount: total, maximumSourceCount: 1, maximumPageByteCount: 1)
        await #expect(throws: SPICESourceCaptureError.self) {
            _ = try await SPICEDeckLoader.load(source: source, fileName: dir.appendingPathComponent("root.sp").path,
                                               capturePolicy: sourceShort)
        }
        #expect(throws: SPICESourceCaptureError.self) {
            _ = try SPICESourceCapturePolicy(maximumTotalByteCount: 10, maximumSourceCount: 1, maximumPageByteCount: 11)
        }
    }

    @Test func invalidUTF8AndReadCloseFailuresRegisterNoSuccessfulCapture() async throws {
        let dir = try directory()
        defer { remove(dir) }
        let file = dir.appendingPathComponent("invalid.sp")
        try Data([0xff, 0xfe]).write(to: file)
        let resolver = SPICECapturingFileResolver()
        await #expect(throws: SPICESourceCaptureError.self) { _ = try await resolver.readFile(at: file.path) }
        #expect(await resolver.capturedSources().isEmpty)
        for failRead in [false, true] {
            let closes = SourceCloseObservation()
            let reader = LocalSPICESourceReader(open: { _ in FailingSourceHandle(failRead: failRead, closes: closes) })
            let failed = SPICECapturingFileResolver(reader: reader)
            do {
                _ = try await failed.readFile(at: file.path)
                Issue.record("Expected read/close failure")
            } catch let error as SPICESourceCaptureError {
                switch (failRead, error) {
                case (false, .closeFailed), (true, .cleanupFailed): break
                default: Issue.record("Wrong source failure: \(error)")
                }
            }
            #expect(closes.count == 1)
            #expect(await failed.capturedSources().isEmpty)
            #expect(await failed.captureFailure() != nil)
        }
    }
}

/// Exclusively owned per-read handle; observation uses a shared Mutex.
private final class FailingSourceHandle: SPICESourceFileHandle {
    let failRead: Bool
    let closes: SourceCloseObservation
    init(failRead: Bool, closes: SourceCloseObservation) { self.failRead = failRead; self.closes = closes }
    func seekToEnd() throws -> UInt64 { 1 }
    func seek(toOffset: UInt64) throws {}
    func read(upToCount: Int) throws -> Data? {
        if failRead { throw SPICESourceCaptureError.readFailed(path: "fixture", reason: "Injected read failure") }
        return Data([0x0a])
    }
    func close() throws {
        closes.state.withLock { $0 += 1 }
        throw SPICESourceCaptureError.closeFailed(path: "fixture", reason: "Injected close failure")
    }
}

private final class SourceCloseObservation: Sendable {
    let state = Mutex(0)
    var count: Int { state.withLock { $0 } }
}
