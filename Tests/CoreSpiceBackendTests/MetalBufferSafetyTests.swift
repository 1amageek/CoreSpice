import Testing
@preconcurrency import Metal
import SharedTypes
@testable import CoreSpiceBackend

@Suite("Metal storage safety")
struct MetalBufferSafetyTests {
    @Test(.timeLimit(.minutes(1)))
    func typedCapacityInitializationAndReentrantBorrow() throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let buffer = try backend.allocateBuffer(type: Float.self, count: 64, label: "64 floats")
        defer { backend.releaseBuffer(buffer) }
        #expect(buffer.length == 256)
        #expect(throws: BackendError.self) {
            try TypedBuffer<Float>(buffer: buffer, count: 65, label: "out of bounds")
        }
        #expect(throws: BackendError.self) {
            try TypedBuffer<UInt32>(buffer: buffer, count: 64, label: "wrong type")
        }
        let view = try TypedBuffer<Float>(buffer: buffer, count: 64, label: "valid")
        try view.withMutableContents { values in
            #expect(values.allSatisfy { $0 == 0 })
            #expect(throws: BackendError.self) {
                try view.withMutableContents { $0[0] = 99 }
            }
            values[0] = 7
        }
        try view.withMutableContents { #expect($0[0] == 7) }
        backend.releaseBuffer(buffer)
        #expect(throws: BackendError.self) { try view.withMutableContents { _ in } }
        let reused = try backend.allocateBuffer(type: Float.self, count: 64, label: "reused")
        defer { backend.releaseBuffer(reused) }
        try backend.withMutableContents(of: reused, as: Float.self) { #expect($0.allSatisfy { $0 == 0 }) }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsInvalidLayerBoundsAndAliasing() async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let state = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "state")
        let coefficients = try backend.allocateBuffer(type: Float.self, count: 256 * 8, label: "coefficients")
        defer { backend.releaseBuffer(state); backend.releaseBuffer(coefficients) }
        for descriptor in [
            LayerDescriptor(offset: 0, count: 257, pattern: 0),
            LayerDescriptor(offset: 1, count: 256, pattern: 1),
            LayerDescriptor(offset: 0, count: 1, pattern: 2),
            LayerDescriptor(offset: UInt32.max, count: 1, pattern: 1),
            LayerDescriptor(offset: 510, count: 2, pattern: 0),
            LayerDescriptor(offset: 0, count: 1, pattern: 1)
        ] {
            await #expect(throws: BackendError.self) {
                try await backend.dispatchMZILayer(stateBuffer: state, coefficients: coefficients,
                    layerDescriptor: descriptor, batchSize: 1, observer: nil, tag: "invalid")
            }
        }
        for batch in [0, 2, Int.max] {
            await #expect(throws: BackendError.self) {
                try await backend.dispatchMZILayer(stateBuffer: state, coefficients: coefficients,
                    layerDescriptor: LayerDescriptor(offset: 0, count: 1, pattern: 0),
                    batchSize: batch, observer: nil, tag: "invalid batch")
            }
        }
        await #expect(throws: BackendError.self) {
            try await backend.dispatchMZILayer(stateBuffer: state, coefficients: state,
                layerDescriptor: LayerDescriptor(offset: 0, count: 1, pattern: 0),
                batchSize: 1, observer: nil, tag: "alias")
        }
        let short = try backend.allocateBuffer(type: Float.self, count: 1, label: "short")
        defer { backend.releaseBuffer(short) }
        await #expect(throws: BackendError.self) {
            try await backend.dispatchMZILayer(stateBuffer: state, coefficients: short,
                layerDescriptor: LayerDescriptor(offset: 0, count: 1, pattern: 0),
                batchSize: 1, observer: nil, tag: "short")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func knownMZIRejectsWrongLogicalElementTypes() async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let state = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "state")
        let coefficients = try backend.allocateBuffer(type: Float.self, count: 8, label: "matrix")
        let wrongState = try backend.allocateBuffer(type: UInt32.self, count: 1_024, label: "wrong state")
        let wrongCoefficients = try backend.allocateBuffer(type: UInt32.self, count: 8, label: "wrong matrix")
        let wrongDescriptor = try backend.allocateBuffer(type: Float.self, count: 3, label: "wrong descriptor")
        defer {
            for buffer in [state, coefficients, wrongState, wrongCoefficients, wrongDescriptor] {
                backend.releaseBuffer(buffer)
            }
        }
        let descriptor = LayerDescriptor(offset: 0, count: 1, pattern: 0)
        await #expect(throws: BackendError.self) {
            try await backend.dispatchMZILayer(stateBuffer: wrongState, coefficients: coefficients,
                layerDescriptor: descriptor, batchSize: 1, observer: nil, tag: "wrong state")
        }
        await #expect(throws: BackendError.self) {
            try await backend.dispatchMZILayer(stateBuffer: state, coefficients: wrongCoefficients,
                layerDescriptor: descriptor, batchSize: 1, observer: nil, tag: "wrong matrix")
        }
        let kernel = try backend.loadKernel(named: "applyLayer512_even")
        await #expect(throws: BackendError.self) {
            try await backend.dispatchAsync(kernel: kernel, buffers: [state, coefficients, wrongDescriptor],
                                            gridSize: GridSize(width: 1))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cpuBorrowRejectsDispatchAndLimitShrink() throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let buffer = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "borrowed")
        defer { backend.releaseBuffer(buffer) }
        #expect(throws: BackendError.self) {
            try backend.prepare(configuration: BackendConfiguration(maxBufferSize: 256))
        }
        let kernel = try backend.loadKernel(named: "applyLayer512_even")
        try backend.withMutableContents(of: buffer, as: Float.self) { _ in
            backend.dispatchAsync(kernel: kernel, buffers: [buffer], gridSize: GridSize(width: 1)) { result in
                switch result {
                case .success: Issue.record("CPU borrowed storage reached GPU dispatch")
                case .failure(let error): #expect(error is BackendError)
                }
            }
        }
    }
}
