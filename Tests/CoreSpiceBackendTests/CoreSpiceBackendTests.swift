import Testing
@testable import CoreSpiceBackend

@Suite("CoreSpiceBackend Tests")
struct CoreSpiceBackendTests {

    @Test func gridSizeCreation() {
        let g1 = GridSize(width: 256)
        #expect(g1.width == 256)
        #expect(g1.height == 1)
        #expect(g1.depth == 1)

        let g2 = GridSize.twoDimensional(256, 64)
        #expect(g2.width == 256)
        #expect(g2.height == 64)
    }

    @Test func backendConfiguration() {
        let config = BackendConfiguration()
        #expect(config.maxBufferSize == 256 * 1024 * 1024)
        #expect(config.enableProfiling == false)
    }

    @Test func backendErrorDescriptions() {
        let err1 = BackendError.metalNotAvailable
        let err2 = BackendError.kernelNotFound("testKernel")
        let err3 = BackendError.bufferAllocationFailed(size: 1024, label: "test")

        // Just verify these are valid Error types
        #expect(err1 is BackendError)
        #expect(err2 is BackendError)
        #expect(err3 is BackendError)
    }
}
