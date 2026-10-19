import Testing
@preconcurrency import Metal
import SharedTypes
import Synchronization
@testable import CoreSpiceBackend

@Suite("Production Metal layer numerics")
struct MetalLayerNumericalTests {
    @Test func sharedABIFieldOrderMatchesPreparedStorage() {
        #expect(MemoryLayout<MZICoefficients>.stride == 32)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m00_real) == 0)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m00_imag) == 4)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m01_real) == 8)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m01_imag) == 12)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m10_real) == 16)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m10_imag) == 20)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m11_real) == 24)
        #expect(MemoryLayout<MZICoefficients>.offset(of: \.m11_imag) == 28)
        #expect(MemoryLayout<LayerDescriptor>.stride == 12)
        #expect(MemoryLayout<LayerDescriptor>.offset(of: \.offset) == 0)
        #expect(MemoryLayout<LayerDescriptor>.offset(of: \.count) == 4)
        #expect(MemoryLayout<LayerDescriptor>.offset(of: \.pattern) == 8)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [0, 1])
    func fullAndPartialLayersMatchClosedForm(pattern: Int) async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let batches = 3
        for (pairs, offset) in [(1, pattern), (1, pattern + 2), (pattern == 0 ? 256 : 255, pattern)] {
            let state = try backend.allocateBuffer(type: Float.self, count: 1_024 * batches, label: "state")
            let coefficients = try backend.allocateBuffer(type: Float.self, count: pairs * 8, label: "matrix")
            defer { backend.releaseBuffer(state); backend.releaseBuffer(coefficients) }
            let inputs = (0..<(1_024 * batches)).map { Float(($0 % 23) - 11) / 16 }
            try backend.withMutableContents(of: state, as: Float.self) { output in
                for i in inputs.indices { output[i] = inputs[i] }
            }
            // (a,b) -> (i*a/2 + b/4, -a/4 + i*b/2), including complex inputs.
            let matrix = MZICoefficients(m00_real: 0, m00_imag: 0.5,
                m01_real: 0.25, m01_imag: 0, m10_real: -0.25, m10_imag: 0,
                m11_real: 0, m11_imag: 0.5)
            try backend.withMutableContents(of: coefficients, as: Float.self) { values in
                for i in 0..<pairs {
                    let base = i * 8
                    values[base] = matrix.m00_real
                    values[base + 1] = matrix.m00_imag
                    values[base + 2] = matrix.m01_real
                    values[base + 3] = matrix.m01_imag
                    values[base + 4] = matrix.m10_real
                    values[base + 5] = matrix.m10_imag
                    values[base + 6] = matrix.m11_real
                    values[base + 7] = matrix.m11_imag
                }
            }
            try await backend.dispatchMZILayer(stateBuffer: state, coefficients: coefficients,
                layerDescriptor: LayerDescriptor(offset: UInt32(offset), count: UInt32(pairs), pattern: UInt32(pattern)),
                batchSize: batches, observer: nil, tag: "reference")
            var expected = inputs
            for batch in 0..<batches {
                for pair in 0..<pairs {
                    let a = batch * 1_024 + (offset + pair * 2) * 2
                    let b = a + 2
                    expected[a] = -inputs[a + 1] / 2 + inputs[b] / 4
                    expected[a + 1] = inputs[a] / 2 + inputs[b + 1] / 4
                    expected[b] = -inputs[a] / 4 - inputs[b + 1] / 2
                    expected[b + 1] = -inputs[a + 1] / 4 + inputs[b] / 2
                }
            }
            try backend.withMutableContents(of: state, as: Float.self) { result in
                #expect(Array(result) == expected)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func synchronizationWaitsForSubmittedCallbacksAndReadback() async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let kernel = try backend.loadKernel(named: "applyLayer512_even")
        let state = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "state")
        let coefficients = try backend.allocateBuffer(type: Float.self, count: 8, label: "swap")
        let descriptor = try backend.allocateBuffer(type: UInt32.self, count: 3, label: "descriptor")
        defer { backend.releaseBuffer(state); backend.releaseBuffer(coefficients); backend.releaseBuffer(descriptor) }
        try backend.withMutableContents(of: state, as: Float.self) { $0[0] = 3; $0[2] = 5 }
        try backend.withMutableContents(of: coefficients, as: Float.self) {
            $0[2] = 1
            $0[4] = 1
        }
        try backend.withMutableContents(of: descriptor, as: UInt32.self) {
            $0[0] = 0; $0[1] = 1; $0[2] = 0
        }
        let outcome = Mutex<Result<Void, Error>?>(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            backend.dispatchAsync(kernel: kernel, buffers: [state, coefficients, descriptor], gridSize: GridSize(width: 1)) { result in
                // Reentrant readback is permitted because GPU access tokens were returned first.
                do {
                    try backend.withMutableContents(of: state, as: Float.self) { #expect($0[0] == 5) }
                } catch { Issue.record("Completion could not read buffer: \(error)") }
                outcome.withLock { $0 = result }
                continuation.resume()
            }
        }
        try outcome.withLock { result in try #require(result).get() }
        // Submit an odd number of swaps without waiting on their callbacks.
        for _ in 0..<31 {
            backend.dispatchAsync(kernel: kernel, buffers: [state, coefficients, descriptor],
                                  gridSize: GridSize(width: 1)) { _ in }
        }
        try await backend.synchronize()
        try backend.withMutableContents(of: state, as: Float.self) { #expect($0[0] == 3) }
    }

    @Test(.timeLimit(.minutes(1)))
    func releaseDefersRecyclingUntilSubmittedWorkFinishes() async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let kernel = try backend.loadKernel(named: "applyLayer512_even")
        let state = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "released state")
        let coefficients = try backend.allocateBuffer(type: Float.self, count: 256 * 8, label: "identity")
        let descriptor = try backend.allocateBuffer(type: UInt32.self, count: 3, label: "full")
        defer { backend.releaseBuffer(coefficients); backend.releaseBuffer(descriptor) }
        try backend.withMutableContents(of: descriptor, as: UInt32.self) {
            $0[0] = 0; $0[1] = 256; $0[2] = 0
        }
        for _ in 0..<32 {
            backend.dispatchAsync(kernel: kernel, buffers: [state, coefficients, descriptor],
                                  gridSize: GridSize(width: 256)) { _ in }
        }
        backend.releaseBuffer(state)
        let next = try backend.allocateBuffer(type: Float.self, count: 1_024, label: "next lease")
        defer { backend.releaseBuffer(next) }
        try backend.withMutableContents(of: next, as: Float.self) { values in
            for i in values.indices { values[i] = 19 }
        }
        try await backend.synchronize()
        try backend.withMutableContents(of: next, as: Float.self) {
            #expect($0.allSatisfy { $0 == 19 })
        }
        #expect(throws: BackendError.self) {
            try backend.withMutableContents(of: state, as: Float.self) { _ in }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func submissionTrackerPreservesFailureAndWaitsForCompletion() async throws {
        let tracker = MetalSubmissionTracker()
        let submission = MetalSubmission()
        let id = tracker.register(submission)
        let completion = Task {
            tracker.complete(id, error: "GPU command failed")
            submission.complete(.failure(.dispatchFailed(kernel: "fault", reason: "GPU command failed")), gpuElapsed: .zero)
        }
        await #expect(throws: BackendError.self) { try await tracker.synchronize() }
        await completion.value
        try await tracker.synchronize()
    }
}
