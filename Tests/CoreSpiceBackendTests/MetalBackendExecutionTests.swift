import Testing
@preconcurrency import Metal
@testable import CoreSpiceBackend

@Suite("Production Metal execution")
struct MetalBackendExecutionTests {
    @Test(.timeLimit(.minutes(1)))
    func dispatchesProductionEvenLayer() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let backend = try MetalBackend(device: device)
        let kernel = try backend.loadKernel(named: "applyLayer512_even")
        let state = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "state")
        defer { backend.releaseBuffer(state) }
        let coefficients = try backend.allocateBuffer(type: Float.self, count: 8, label: "swap")
        defer { backend.releaseBuffer(coefficients) }
        let descriptor = try backend.allocateBuffer(type: UInt32.self, count: 3, label: "layer")
        defer { backend.releaseBuffer(descriptor) }

        // Buffers own POD storage; scoped borrows initialize it and never escape.
        // The production kernel consumes eight Float coefficients and three UInt32 fields.
        try backend.withMutableContents(of: state, as: Float.self) { values in
            for index in values.indices { values[index] = 0 }
            values[0] = 1
            values[1] = 2
            values[2] = 3
            values[3] = 4
        }
        try backend.withMutableContents(of: coefficients, as: Float.self) { values in
            for index in values.indices { values[index] = 0 }
            values[2] = 1
            values[4] = 1
        }
        try backend.withMutableContents(of: descriptor, as: UInt32.self) { values in
            for index in values.indices { values[index] = 0 }
            values[1] = 1
        }

        try await backend.dispatch(
            kernel: kernel,
            buffers: [state, coefficients, descriptor],
            gridSize: GridSize(width: 1),
            observer: nil,
            tag: "production-even-layer"
        )
        try backend.withMutableContents(of: state, as: Float.self) { values in
            #expect(values[0] == 3)
            #expect(values[1] == 4)
            #expect(values[2] == 1)
            #expect(values[3] == 2)
            #expect(values.dropFirst(4).allSatisfy { $0 == 0 })
        }
    }
}
