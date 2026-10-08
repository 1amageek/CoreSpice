import CoreSpiceIO
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("CLI captured input references")
struct CapturedInputReferenceTests {
    @Test func inputReferenceUsesConsumedBytesAfterOriginalFileDisappears() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("captured-input-\(UUID().uuidString).sp")
        let source = ".model sheet R r=100\r\n+ tc1=0.001\r\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try await SPICEDeckLoader.loadFile(at: file.path)
        try FileManager.default.removeItem(at: file)
        let capture = try #require(loaded.captures.first)
        let referencer = try CoreSpiceCLIArtifactReferencer()
        let reference = referencer.input(capture: capture, kind: .netlist, format: .spice)
        #expect(reference.byteCount == UInt64(source.utf8.count))
        #expect(reference.digest.hexadecimalValue == "1b565d592c16ff91837a66cf29470a922ebb6eae99780dfd87a2b5a41de7094a")
        #expect(reference.descriptor.role == .input)
    }

    @Test func captureFailureCodesRemainDistinctFromSPICESyntax() {
        for (error, code) in [
            (SPICESourceCaptureError.totalByteLimitExceeded(limit: 10, requested: 11), "io.source-capture-budget"),
            (.sourceCountLimitExceeded(limit: 1), "io.source-capture-budget"),
            (.invalidUTF8(path: "source.sp"), "io.source-encoding"),
            (.closeFailed(path: "source.sp", reason: "checked close failed"), "io.source-close"),
            (.readFailed(path: "source.sp", reason: "missing source"), "io.file-read")
        ] {
            let failure = CoreSpiceCLIFailure(error: error)
            #expect(failure.status == "failed")
            #expect(failure.stage == "load")
            #expect(failure.code == code)
            #expect(failure.suggestedActions?.isEmpty == false)
        }
    }
}
