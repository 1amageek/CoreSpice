import Testing
@preconcurrency import Metal
import Synchronization
@testable import CoreSpiceBackend

@Suite("Metal descriptor snapshot admission")
struct MetalDescriptorSnapshotTests {
    @Test(.timeLimit(.minutes(1)))
    func queuedGPUDescriptorWriterRejectsCPUAdmission() async throws {
        let (backend, writer) = try await makeWriterBackend()
        let state = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "state")
        let coefficients = try backend.allocateBuffer(type: Float.self, count: 8, label: "matrix")
        let descriptor = try backend.allocateBuffer(type: UInt32.self, count: 3, label: "descriptor")
        defer { for buffer in [state, coefficients, descriptor] { backend.releaseBuffer(buffer) } }
        try backend.withMutableContents(of: descriptor, as: UInt32.self) { $0[1] = 1 }
        let kernel = try backend.loadKernel(named: "applyLayer512_even")
        // The bounded writer performs real serial device atomics. Its GPU token
        // exists before dispatchAsync returns, before descriptor capture is attempted.
        backend.dispatchAsync(kernel: writer, buffers: [descriptor], gridSize: GridSize(width: 1)) { _ in }
        let outcome = Mutex<Result<Void, Error>?>(nil)
        backend.dispatchAsync(kernel: kernel, buffers: [state, coefficients, descriptor],
                              gridSize: GridSize(width: 1)) { result in outcome.withLock { $0 = result } }
        let result = try #require(outcome.withLock { $0 })
        switch result {
        case .success: Issue.record("CPU admission read a descriptor with a queued GPU writer")
        case .failure(let error):
            guard case .bufferAccessConflict? = error as? BackendError else {
                Issue.record("Expected descriptor access conflict, received \(error)")
                return
            }
        }
        try await backend.synchronize()
        // The completed writer restores a valid descriptor that can be captured.
        try await backend.dispatchAsync(kernel: kernel, buffers: [state, coefficients, descriptor],
                                        gridSize: GridSize(width: 1))
    }

    @Test(.timeLimit(.minutes(1)))
    func submittedLayerUsesCapturedDescriptorAfterItsBufferChanges() async throws {
        let (backend, writer) = try await makeWriterBackend()
        let state = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "state")
        let coefficients = try backend.allocateBuffer(type: Float.self, count: 8, label: "swap")
        let descriptor = try backend.allocateBuffer(type: UInt32.self, count: 3, label: "descriptor")
        let precedingWork = try backend.allocateBuffer(type: UInt32.self, count: 3, label: "preceding work")
        defer { for buffer in [state, coefficients, descriptor, precedingWork] { backend.releaseBuffer(buffer) } }
        try backend.withMutableContents(of: state, as: Float.self) { $0[0] = 3; $0[2] = 5 }
        try backend.withMutableContents(of: coefficients, as: Float.self) { $0[2] = 1; $0[4] = 1 }
        try backend.withMutableContents(of: descriptor, as: UInt32.self) { $0[1] = 1 }
        let kernel = try backend.loadKernel(named: "applyLayer512_even")
        backend.dispatchAsync(kernel: writer, buffers: [precedingWork], gridSize: GridSize(width: 1)) { _ in }
        backend.dispatchAsync(kernel: kernel, buffers: [state, coefficients, descriptor],
                              gridSize: GridSize(width: 1)) { _ in }
        // Descriptor storage is no longer a GPU input after its exclusive capture.
        // These invalid values must never reach the already-admitted layer kernel.
        try backend.withMutableContents(of: descriptor, as: UInt32.self) {
            $0[0] = UInt32.max; $0[1] = 257; $0[2] = 1
        }
        try await backend.synchronize()
        try backend.withMutableContents(of: state, as: Float.self) {
            #expect($0[0] == 5)
            #expect($0[2] == 3)
            #expect($0.dropFirst(3).allSatisfy { $0 == 0 })
        }
    }

    private func makeWriterBackend() async throws -> (MetalBackend, MetalKernel) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = PhotonicMetalLibrarySource.source + "\n" + """
            kernel void writeLayerDescriptor(device atomic_uint* descriptor [[buffer(0)]]) {
                for (uint i = 0; i < 1048576; ++i) {
                    atomic_fetch_add_explicit(descriptor, 1u, memory_order_relaxed);
                }
                atomic_store_explicit(descriptor, 0u, memory_order_relaxed);
                atomic_store_explicit(descriptor + 1, 1u, memory_order_relaxed);
                atomic_store_explicit(descriptor + 2, 0u, memory_order_relaxed);
            }
            """
        let library = try await device.makeLibrary(source: source, options: nil)
        let backend = try MetalBackend(device: device, library: library)
        return (backend, try backend.loadKernel(named: "writeLayerDescriptor"))
    }
}
