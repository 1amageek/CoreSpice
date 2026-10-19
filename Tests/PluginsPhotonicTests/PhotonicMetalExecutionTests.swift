import Foundation
import Testing
@preconcurrency import Metal
import SharedTypes
import CoreSpiceBackend
import CoreSpiceEvent
@testable import PluginsPhotonic

@Suite("Photonic production Metal execution")
struct PhotonicMetalExecutionTests {
    @Test(.timeLimit(.minutes(1)))
    func multiwavelengthMultibatchMatchesIndependentMatrixProducts() async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let model = WavelengthModel(groupIndex: 4.2, dispersion: 2e-3, armLengthImbalance: 2e-6)
        let layers = [
            MeshLayer(pattern: .even, blocks: Array(repeating: MZIBlock(theta: 1.1, phi: 0.3, loss: 0.9), count: 256)),
            MeshLayer(pattern: .odd, blocks: Array(repeating: MZIBlock(theta: -0.7, phi: -0.2, loss: 0.8), count: 255)),
            MeshLayer(pattern: .even, blocks: [MZIBlock(theta: 0.4, phi: 0.6)]),
            MeshLayer(pattern: .odd, blocks: [MZIBlock(theta: 0.8, phi: -0.1)])
        ]
        let wavelengths = [1540e-9, 1550e-9, 1560e-9]
        let result = try await PhotonicExecutor().execute(
            mesh: PhotonicMesh512(layers: layers, wavelengthModel: model),
            batch: PhotonicSweepBatch(wavelengths: wavelengths, repetitions: 3),
            backend: backend, observer: nil, cancellation: CancellationToken())
        #expect(result.wavelengthResults.count == wavelengths.count)
        for (index, wavelength) in wavelengths.enumerated() {
            var real = Array(repeating: 0.0, count: 512)
            var imaginary = real
            real[0] = 1
            for layer in layers {
                for (pair, block) in layer.blocks.enumerated() {
                    let a = Int(layer.pattern.rawValue) + pair * 2
                    let b = a + 1
                    let deviation = wavelength - model.centerWavelength
                    let firstOrder = -2 * Double.pi * model.groupIndex * deviation / pow(model.centerWavelength, 2)
                    let secondOrder = (2 * Double.pi * model.groupIndex / pow(model.centerWavelength, 3) -
                        Double.pi * 299_792_458 * model.dispersion / pow(model.centerWavelength, 2)) * deviation * deviation
                    let theta = block.theta + model.armLengthImbalance * (firstOrder + secondOrder)
                    let c = cos(theta / 2), s = sin(theta / 2)
                    // First apply the symmetric splitter, then opposite arm phase rotations.
                    let ar = c * real[a] - s * imaginary[b]
                    let ai = c * imaginary[a] + s * real[b]
                    let br = c * real[b] - s * imaginary[a]
                    let bi = c * imaginary[b] + s * real[a]
                    real[a] = block.loss * (ar * cos(block.phi) - ai * sin(block.phi))
                    imaginary[a] = block.loss * (ar * sin(block.phi) + ai * cos(block.phi))
                    real[b] = block.loss * (br * cos(block.phi) + bi * sin(block.phi))
                    imaginary[b] = block.loss * (-br * sin(block.phi) + bi * cos(block.phi))
                }
            }
            for port in 0..<512 {
                let output = result.wavelengthResults[index].outputs[port]
                #expect(abs(Double(output.real) - real[port]) < 2e-6)
                #expect(abs(Double(output.imag) - imaginary[port]) < 2e-6)
            }
            #expect(result.wavelengthResults[index].totalOutputPower <= 1.00001)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func largeFiniteAveragesAndMetricsStayFinite() async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let result = try await PhotonicExecutor().execute(
            mesh: PhotonicMesh512(layers: [MeshLayer(pattern: .even, blocks: [.identity])]),
            batch: PhotonicSweepBatch(wavelengths: [1550e-9], repetitions: 2,
                                      inputAmplitude: Double(Float.greatestFiniteMagnitude)),
            backend: backend, observer: nil, cancellation: CancellationToken())
        let wavelength = try #require(result.wavelengthResults.first)
        let output = try #require(wavelength.outputs.first)
        #expect(output.real == Float.greatestFiniteMagnitude)
        #expect(output.imag == 0)
        #expect(output.power.isFinite)
        #expect(output.amplitude.isFinite)
        #expect(wavelength.totalOutputPower.isFinite)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationAfterLastGPUDispatchEmitsCancelled() async throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let cancellation = CancellationToken()
        let captured = try BufferingObserver(capacity: 64)
        let observer = EventDispatcher(observers: [CancelAfterGPU(cancellation: cancellation), captured])
        await #expect(throws: PhotonicExecutionError.self) {
            try await PhotonicExecutor().execute(
                mesh: PhotonicMesh512(layers: [MeshLayer(pattern: .even, blocks: [.identity])]),
                batch: PhotonicSweepBatch(wavelengths: [1550e-9]),
                backend: backend, observer: observer, cancellation: cancellation)
        }
        let terminal = captured.events.compactMap { event -> AnalysisStatus? in
            if case .analysisFinished(let info) = event { return info.status }
            return nil
        }
        #expect(terminal == [.cancelled])
    }

    @Test(.timeLimit(.minutes(1)))
    func nonFiniteGPUReadbackEmitsFailed() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try await device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            kernel void applyLayer512_even(device float2* state [[buffer(0)]],
                                          uint2 tid [[thread_position_in_grid]]) {
                state[tid.y * 512 + tid.x * 2] = float2(as_type<float>(0x7fc00000u), 0);
            }
            """, options: nil)
        let backend = try MetalBackend(device: device, library: library)
        let captured = try BufferingObserver(capacity: 64)
        let observer = EventDispatcher(observers: [captured])
        await #expect(throws: PhotonicExecutionError.self) {
            try await PhotonicExecutor().execute(
                mesh: PhotonicMesh512(layers: [MeshLayer(pattern: .even, blocks: [.identity])]),
                batch: PhotonicSweepBatch(wavelengths: [1550e-9]),
                backend: backend, observer: observer, cancellation: CancellationToken())
        }
        let terminal = captured.events.compactMap { event -> AnalysisStatus? in
            if case .analysisFinished(let info) = event { return info.status }
            return nil
        }
        #expect(terminal == [.failed])
    }

    @Test(.timeLimit(.minutes(1)))
    func sizingRejectsLimitsAndOverflowWithoutAllocation() throws {
        let backend = try MetalBackend(device: #require(MTLCreateSystemDefaultDevice()))
        let resources = PhotonicGPUResources(backend: backend, maxBatchSize: 2)
        for count in [0, 3, Int.max] {
            #expect(throws: PhotonicExecutionError.self) { try resources.allocateStateBuffer(batchSize: count) }
        }
        let overflow = PhotonicGPUResources(backend: backend, maxBatchSize: Int.max, portCount: Int.max)
        #expect(throws: PhotonicExecutionError.self) { try overflow.allocateStateBuffer(batchSize: 2) }
        for pairs in [0, 257, Int.max] {
            #expect(throws: PhotonicExecutionError.self) { try resources.allocateCoefficientsBuffer(pairCount: pairs) }
        }
    }
}

private struct CancelAfterGPU: AnalysisObserver {
    let cancellation: CancellationToken
    func onEvent(_ event: AnalysisEvent) {
        if case .gpuDispatchFinished = event { cancellation.cancel() }
    }
}
