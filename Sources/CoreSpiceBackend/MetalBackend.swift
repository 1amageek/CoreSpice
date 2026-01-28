@preconcurrency import Metal
import CoreSpiceEvent
import SharedTypes
import Synchronization

public final class MetalBackend: ComputeBackend, PhotonicComputeBackend, Sendable {

    public typealias BufferHandle = MTLBuffer
    public typealias KernelHandle = MTLComputePipelineState

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let pool: BufferPool

    public init(device: MTLDevice? = nil, library: MTLLibrary? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            throw BackendError.metalNotAvailable
        }
        self.device = dev

        guard let queue = dev.makeCommandQueue() else {
            throw BackendError.metalNotAvailable
        }
        self.commandQueue = queue

        if let lib = library {
            self.library = lib
        } else {
            do {
                self.library = try dev.makeDefaultLibrary(bundle: Bundle.module)
            } catch {
                throw BackendError.shaderCompilationFailed(
                    "Failed to load shader library: \(error.localizedDescription)"
                )
            }
        }

        self.pool = BufferPool(device: dev)
    }

    public static func createIfAvailable() -> MetalBackend? {
        do {
            return try MetalBackend()
        } catch {
            return nil
        }
    }

    // MARK: - ComputeBackend

    public func allocateBuffer<T: Sendable>(
        type: T.Type,
        count: Int,
        label: String
    ) throws -> MTLBuffer {
        let byteCount = count * MemoryLayout<T>.stride
        return try pool.acquire(byteCount: byteCount, label: label)
    }

    public func contents<T>(
        of buffer: MTLBuffer,
        as type: T.Type
    ) -> UnsafeMutableBufferPointer<T> {
        let count = buffer.length / MemoryLayout<T>.stride
        let ptr = buffer.contents().bindMemory(to: T.self, capacity: count)
        return UnsafeMutableBufferPointer(start: ptr, count: count)
    }

    public func releaseBuffer(_ buffer: MTLBuffer) {
        pool.release(buffer)
    }

    public func loadKernel(named name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw BackendError.kernelNotFound(name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw BackendError.shaderCompilationFailed(
                "Failed to create pipeline for '\(name)': \(error.localizedDescription)"
            )
        }
    }

    public func dispatch(
        kernel: MTLComputePipelineState,
        buffers: [MTLBuffer],
        gridSize: GridSize,
        observer: EventDispatcher?,
        tag: String
    ) throws {
        let analysisID = AnalysisID()
        let startTime = Timestamp()

        observer?.emit(.gpuDispatchStarted(GpuDispatchInfo(
            id: analysisID,
            kernelName: tag,
            gridSize: GridDimensions(width: gridSize.width, height: gridSize.height),
            tag: tag
        )))

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BackendError.dispatchFailed(
                kernel: tag,
                reason: "Failed to create command buffer"
            )
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BackendError.dispatchFailed(
                kernel: tag,
                reason: "Failed to create compute command encoder"
            )
        }

        encoder.setComputePipelineState(kernel)
        for (index, buffer) in buffers.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }

        let threadgroupWidth = min(
            kernel.maxTotalThreadsPerThreadgroup,
            gridSize.width
        )
        let threadgroupSize = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
        let gridSizeMTL = MTLSize(
            width: gridSize.width,
            height: gridSize.height,
            depth: gridSize.depth
        )

        encoder.dispatchThreads(gridSizeMTL, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw BackendError.dispatchFailed(
                kernel: tag,
                reason: error.localizedDescription
            )
        }

        observer?.emit(.gpuDispatchFinished(GpuDispatchResultInfo(
            id: analysisID,
            kernelName: tag,
            elapsedTime: Timestamp().elapsed(since: startTime),
            tag: tag
        )))
    }

    public func synchronize() async throws {
        // Metal commands are committed synchronously in dispatch,
        // so no additional synchronization is required.
    }

    public func prepare(configuration: BackendConfiguration) throws {
        // Configuration is applied at init time.
        // Buffer pool size is fixed at construction.
    }

    public func reset() {
        pool.drain()
    }

    // MARK: - PhotonicComputeBackend

    public func dispatchMZILayer(
        stateBuffer: MTLBuffer,
        coefficients: MTLBuffer,
        layerDescriptor: LayerDescriptor,
        batchSize: Int,
        observer: EventDispatcher?,
        tag: String
    ) throws {
        let kernelName = layerDescriptor.pattern == 0
            ? "applyLayer512_even"
            : "applyLayer512_odd"

        let kernel = try loadKernel(named: kernelName)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BackendError.dispatchFailed(
                kernel: kernelName,
                reason: "Failed to create command buffer"
            )
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BackendError.dispatchFailed(
                kernel: kernelName,
                reason: "Failed to create compute command encoder"
            )
        }

        encoder.setComputePipelineState(kernel)
        encoder.setBuffer(stateBuffer, offset: 0, index: 0)
        encoder.setBuffer(coefficients, offset: 0, index: 1)

        var descriptor = layerDescriptor
        encoder.setBytes(&descriptor, length: MemoryLayout<LayerDescriptor>.stride, index: 2)

        let pairCount = Int(layerDescriptor.count)
        let threadgroupWidth = min(kernel.maxTotalThreadsPerThreadgroup, pairCount)
        let threadgroupSize = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
        let gridSizeMTL = MTLSize(width: pairCount, height: batchSize, depth: 1)

        encoder.dispatchThreads(gridSizeMTL, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw BackendError.dispatchFailed(
                kernel: kernelName,
                reason: error.localizedDescription
            )
        }
    }
}
