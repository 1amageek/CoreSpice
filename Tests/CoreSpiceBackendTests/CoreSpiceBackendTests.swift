import Testing
@preconcurrency import Metal
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

        guard case .metalNotAvailable = err1 else {
            Issue.record("Expected metalNotAvailable error.")
            return
        }
        guard case .kernelNotFound("testKernel") = err2 else {
            Issue.record("Expected kernelNotFound error.")
            return
        }
        guard case .bufferAllocationFailed(size: 1024, label: "test") = err3 else {
            Issue.record("Expected bufferAllocationFailed error.")
            return
        }
    }

    @Test func metalBackendLoadsDefaultPhotonicKernelsWhenAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return
        }

        let backend = try MetalBackend()
        _ = try backend.loadKernel(named: "applyLayer512_even")
        _ = try backend.loadKernel(named: "applyLayer512_odd")
    }
}
