import CoreSpice
import CoreSpiceIO
@testable import CoreSpiceCLICore
import Foundation
import Testing

@Suite("Prepared CLI owns exact native input", .timeLimit(.minutes(1)))
struct PreparedCLIExecutionTests {
    @Test func actualCatalogCLIExecutesRetainedOwnerAfterFilesChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {
            do { try FileManager.default.removeItem(at:directory) }
            catch { Issue.record("Temporary fixture cleanup failed: \(error)") }
        }
        let root = directory.appendingPathComponent("root.cir")
        let library = directory.appendingPathComponent("metal.lib")
        let original = "cli owned\n.lib 'metal.lib' tt\nV1 out 0 2\nR1 out 0 metal\n.op\n.end\n"
        try original.write(to:root,atomically:true,encoding:.utf8)
        try "library\n.lib tt\n.model metal R r=1k\n.endl\n".write(to:library,atomically:true,encoding:.utf8)
        let output = try await CoreSpicePreparedCommand(arguments:[root.path,"--source","metal",library.path,
            "--library","root","metal.lib","metal","tt"]).execute()
        try "changed\nV1 out 0 9\nR1 out 0 1k\n.op\n.end\n".write(to:root,atomically:true,encoding:.utf8)
        try "changed library\n.end\n".write(to:library,atomically:true,encoding:.utf8)
        let repeated = try await SPICENativeSimulation().execute(output.prepared,cancellation:.init())
        #expect(output.prepared.input.sources.count == 2)
        #expect(String(decoding:output.prepared.input.sources[0].bytes,as:UTF8.self) == original)
        #expect(output.configurationIdentity == repeated.configurationIdentity)
        let voltage = try #require(repeated.waveform.variables.firstIndex { $0.name.lowercased() == "v(out)" })
        #expect(abs(try #require(repeated.waveform.realValue(variable:voltage,point:0))-2) < 1e-8)
        #expect(repeated.executedModels.contains { $0.model?.name.lowercased() == "metal" })
    }
}
