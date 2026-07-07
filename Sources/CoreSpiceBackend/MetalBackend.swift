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

    /// Maximum buffer size in bytes (configurable).
    private let maxBufferSize: Mutex<Int>

    /// Whether profiling is enabled.
    private let profilingEnabled: Mutex<Bool>

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
                self.library = try MetalBackend.makeDefaultLibrary(device: dev)
            } catch {
                throw BackendError.shaderCompilationFailed(
                    "Failed to load shader library: \(error.localizedDescription)"
                )
            }
        }

        self.pool = BufferPool(device: dev)
        self.maxBufferSize = Mutex(256 * 1024 * 1024)  // Default: 256 MB
        self.profilingEnabled = Mutex(false)
    }

    /// Initialize with a specific device name (for multi-GPU systems).
    public init(deviceName: String, library: MTLLibrary? = nil) throws {
        // Find the device by name
        let devices = MTLCopyAllDevices()
        guard !devices.isEmpty else {
            throw BackendError.metalNotAvailable
        }
        guard let matchedDevice = devices.first(where: { $0.name == deviceName }) else {
            throw BackendError.deviceNotFound(deviceName)
        }

        self.device = matchedDevice

        guard let queue = matchedDevice.makeCommandQueue() else {
            throw BackendError.metalNotAvailable
        }
        self.commandQueue = queue

        if let lib = library {
            self.library = lib
        } else {
            do {
                self.library = try MetalBackend.makeDefaultLibrary(device: matchedDevice)
            } catch {
                throw BackendError.shaderCompilationFailed(
                    "Failed to load shader library: \(error.localizedDescription)"
                )
            }
        }

        self.pool = BufferPool(device: matchedDevice)
        self.maxBufferSize = Mutex(256 * 1024 * 1024)
        self.profilingEnabled = Mutex(false)
    }

    private static func makeDefaultLibrary(device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(source: PhotonicMetalLibrarySource.source, options: nil)
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
    ) async throws {
        let analysisID = AnalysisID()
        let startTime = Timestamp()

        await observer?.emit(.gpuDispatchStarted(GpuDispatchInfo(
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
        await commandBuffer.completed()

        if let error = commandBuffer.error {
            throw BackendError.dispatchFailed(
                kernel: tag,
                reason: error.localizedDescription
            )
        }

        await observer?.emit(.gpuDispatchFinished(GpuDispatchResultInfo(
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
        if let preferredDevice = configuration.preferredDevice,
           preferredDevice != device.name {
            throw BackendError.preferredDeviceMismatch(
                requested: preferredDevice,
                active: device.name
            )
        }

        // Apply max buffer size configuration
        maxBufferSize.withLock { $0 = configuration.maxBufferSize }

        // Apply profiling configuration
        profilingEnabled.withLock { $0 = configuration.enableProfiling }
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
    ) async throws {
        let kernelName = layerDescriptor.pattern == 0
            ? "applyLayer512_even"
            : "applyLayer512_odd"

        let analysisID = AnalysisID()
        let startTime = Timestamp()
        let pairCount = Int(layerDescriptor.count)

        // Emit dispatch started event
        await observer?.emit(.gpuDispatchStarted(GpuDispatchInfo(
            id: analysisID,
            kernelName: kernelName,
            gridSize: GridDimensions(width: pairCount, height: batchSize),
            tag: tag
        )))

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

        let threadgroupWidth = min(kernel.maxTotalThreadsPerThreadgroup, pairCount)
        let threadgroupSize = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
        let gridSizeMTL = MTLSize(width: pairCount, height: batchSize, depth: 1)

        encoder.dispatchThreads(gridSizeMTL, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()

        if let error = commandBuffer.error {
            throw BackendError.dispatchFailed(
                kernel: kernelName,
                reason: error.localizedDescription
            )
        }

        // Emit dispatch finished event
        await observer?.emit(.gpuDispatchFinished(GpuDispatchResultInfo(
            id: analysisID,
            kernelName: kernelName,
            elapsedTime: Timestamp().elapsed(since: startTime),
            tag: tag
        )))
    }

    // MARK: - Async Dispatch Support

    /// Dispatch a kernel asynchronously and call completion handler when done.
    ///
    /// - Parameters:
    ///   - kernel: The compute pipeline state to execute.
    ///   - buffers: Buffers to bind to the kernel.
    ///   - gridSize: The dispatch grid dimensions.
    ///   - completion: Called when the dispatch completes or fails.
    public func dispatchAsync(
        kernel: MTLComputePipelineState,
        buffers: [MTLBuffer],
        gridSize: GridSize,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion(.failure(BackendError.dispatchFailed(
                kernel: "async",
                reason: "Failed to create command buffer"
            )))
            return
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            completion(.failure(BackendError.dispatchFailed(
                kernel: "async",
                reason: "Failed to create compute command encoder"
            )))
            return
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

        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
                completion(.failure(BackendError.dispatchFailed(
                    kernel: "async",
                    reason: error.localizedDescription
                )))
            } else {
                completion(.success(()))
            }
        }

        commandBuffer.commit()
    }

    /// Dispatch a kernel asynchronously using Swift concurrency.
    ///
    /// - Parameters:
    ///   - kernel: The compute pipeline state to execute.
    ///   - buffers: Buffers to bind to the kernel.
    ///   - gridSize: The dispatch grid dimensions.
    public func dispatchAsync(
        kernel: MTLComputePipelineState,
        buffers: [MTLBuffer],
        gridSize: GridSize
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            dispatchAsync(kernel: kernel, buffers: buffers, gridSize: gridSize) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
