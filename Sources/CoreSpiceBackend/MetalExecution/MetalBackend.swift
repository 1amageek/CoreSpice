@preconcurrency import Metal
import CoreSpiceEvent
import SharedTypes
import Synchronization

public final class MetalBackend: ComputeBackend, PhotonicComputeBackend, Sendable {

    public typealias BufferHandle = MetalBuffer
    public typealias KernelHandle = MetalKernel

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let pool: BufferPool
    private let submissions = MetalSubmissionTracker()

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

        self.pool = try BufferPool(device: dev)
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

        self.pool = try BufferPool(device: matchedDevice)
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

    public func allocateBuffer<T: GPUBufferElement>(
        type: T.Type, count: Int, label: String
    ) throws -> MetalBuffer {
        try pool.acquire(type: type, count: count, label: label)
    }

    public func withMutableContents<T: GPUBufferElement, Result>(
        of buffer: MetalBuffer, as type: T.Type,
        _ body: (UnsafeMutableBufferPointer<T>) throws -> Result
    ) throws -> Result {
        try buffer.withMutableContents(as: type, body)
    }

    public func releaseBuffer(_ buffer: MetalBuffer) { pool.release(buffer) }

    public func loadKernel(named name: String) throws -> MetalKernel {
        guard let function = library.makeFunction(name: name) else {
            throw BackendError.kernelNotFound(name)
        }
        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            return MetalKernel(name: name, pipeline: pipeline, ownerID: ObjectIdentifier(pool))
        } catch {
            throw BackendError.shaderCompilationFailed(
                "Failed to create pipeline for '\(name)': \(error.localizedDescription)")
        }
    }

    public func dispatch(
        kernel: MetalKernel, buffers: [MetalBuffer], gridSize: GridSize,
        observer: EventDispatcher?, tag: String
    ) async throws {
        try validate(gridSize: gridSize)
        let analysisID = AnalysisID()
        let start = Timestamp()
        await observer?.emit(.gpuDispatchStarted(GPUDispatchInfo(
            id: analysisID, kernelName: tag,
            gridSize: GridDimensions(width: gridSize.width, height: gridSize.height), tag: tag)))
        let submission = try submit(kernel: kernel, buffers: buffers, gridSize: gridSize)
        try await submission.wait()
        await observer?.emit(.gpuDispatchFinished(GPUDispatchResultInfo(
            id: analysisID, kernelName: tag,
            elapsedTime: profilingEnabled.withLock { $0 } ? submission.gpuElapsed : Timestamp().elapsed(since: start), tag: tag)))
    }

    public func synchronize() async throws { try await submissions.synchronize() }

    public func prepare(configuration: BackendConfiguration) throws {
        try configuration.validate()
        if let preferredDevice = configuration.preferredDevice, preferredDevice != device.name {
            throw BackendError.preferredDeviceMismatch(requested: preferredDevice, active: device.name)
        }
        try pool.setMaximumBufferSize(configuration.maxBufferSize)
        profilingEnabled.withLock { $0 = configuration.enableProfiling }
    }

    public func reset() { pool.drain() }

    public func dispatchMZILayer(
        stateBuffer: MetalBuffer, coefficients: MetalBuffer,
        layerDescriptor: LayerDescriptor, batchSize: Int,
        observer: EventDispatcher?, tag: String
    ) async throws {
        try validateLayer(stateBuffer: stateBuffer, coefficients: coefficients,
                          descriptor: layerDescriptor, batchSize: batchSize)
        let kernelName = layerDescriptor.pattern == 0 ? "applyLayer512_even" : "applyLayer512_odd"
        let kernel = try loadKernel(named: kernelName)
        let id = AnalysisID()
        let start = Timestamp()
        await observer?.emit(.gpuDispatchStarted(GPUDispatchInfo(
            id: id, kernelName: kernelName,
            gridSize: GridDimensions(width: Int(layerDescriptor.count), height: batchSize), tag: tag)))
        let submission = try submit(
            kernel: kernel, buffers: [stateBuffer, coefficients],
            gridSize: GridSize(width: Int(layerDescriptor.count), height: batchSize),
            descriptor: layerDescriptor)
        try await submission.wait()
        await observer?.emit(.gpuDispatchFinished(GPUDispatchResultInfo(
            id: id, kernelName: kernelName,
            elapsedTime: profilingEnabled.withLock { $0 } ? submission.gpuElapsed : Timestamp().elapsed(since: start), tag: tag)))
    }

    public func dispatchAsync(
        kernel: MetalKernel, buffers: [MetalBuffer], gridSize: GridSize,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        do {
            _ = try submit(kernel: kernel, buffers: buffers, gridSize: gridSize, completion: completion)
        } catch { completion(.failure(error)) }
    }

    public func dispatchAsync(
        kernel: MetalKernel, buffers: [MetalBuffer], gridSize: GridSize
    ) async throws {
        let submission = try submit(kernel: kernel, buffers: buffers, gridSize: gridSize)
        try await submission.wait()
    }

    private func submit(
        kernel: MetalKernel, buffers: [MetalBuffer], gridSize: GridSize,
        descriptor: LayerDescriptor? = nil,
        completion: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) throws -> MetalSubmission {
        try validate(gridSize: gridSize)
        guard kernel.ownerID == ObjectIdentifier(pool) else {
            throw BackendError.invalidConfiguration("kernel belongs to another backend")
        }
        for buffer in buffers {
            guard buffer.ownerID == ObjectIdentifier(pool) else {
                throw BackendError.invalidConfiguration("buffer belongs to another backend")
            }
        }
        let submittedBuffers: [MetalBuffer]
        let capturedDescriptor: LayerDescriptor?
        if descriptor == nil,
           kernel.name == "applyLayer512_even" || kernel.name == "applyLayer512_odd" {
            guard buffers.count == 3, gridSize.depth == 1,
                  buffers[2] !== buffers[0], buffers[2] !== buffers[1] else {
                throw BackendError.invalidLayerDescriptor("MZI dispatch requires separate state, coefficients and descriptor")
            }
            // Capture under an exclusive CPU borrow before admitting GPU accesses.
            // This rejects queued GPU writers and stops descriptor TOCTOU races:
            // the GPU receives setBytes, never the mutable descriptor allocation.
            let layer = try buffers[2].withMutableContents(as: UInt32.self, count: 3) { fields in
                LayerDescriptor(offset: fields[0], count: fields[1], pattern: fields[2])
            }
            guard (kernel.name == "applyLayer512_even" ? UInt32(0) : UInt32(1)) == layer.pattern,
                  gridSize.width <= Int(layer.count) else {
                throw BackendError.invalidLayerDescriptor("kernel and layer pattern differ")
            }
            try validateLayer(stateBuffer: buffers[0], coefficients: buffers[1],
                              descriptor: layer, batchSize: gridSize.height)
            capturedDescriptor = layer
            submittedBuffers = [buffers[0], buffers[1]]
        } else {
            capturedDescriptor = descriptor
            submittedBuffers = buffers
        }
        var acquired: [MetalBuffer] = []
        do {
            for buffer in submittedBuffers {
                try buffer.beginGPUAccess()
                acquired.append(buffer)
            }
            guard let command = commandQueue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else {
                throw BackendError.dispatchFailed(kernel: kernel.name, reason: "Cannot create command encoder")
            }
            encoder.setComputePipelineState(kernel.pipeline)
            for (index, buffer) in submittedBuffers.enumerated() {
                encoder.setBuffer(buffer.storage, offset: 0, index: index)
            }
            if var descriptor = capturedDescriptor {
                encoder.setBytes(&descriptor, length: MemoryLayout<LayerDescriptor>.stride, index: 2)
            }
            encoder.dispatchThreads(
                MTLSize(width: gridSize.width, height: gridSize.height, depth: gridSize.depth),
                threadsPerThreadgroup: MTLSize(
                    width: min(kernel.pipeline.maxTotalThreadsPerThreadgroup, gridSize.width), height: 1, depth: 1))
            encoder.endEncoding()
            let submission = MetalSubmission()
            let id = submissions.register(submission)
            command.addCompletedHandler { [submissions, submittedBuffers] command in
                let failure = command.error.map {
                    BackendError.dispatchFailed(kernel: kernel.name, reason: $0.localizedDescription)
                }
                for buffer in submittedBuffers { buffer.endGPUAccess() }
                submissions.complete(id, error: failure?.localizedDescription)
                let result: Result<Void, BackendError> = failure.map { .failure($0) } ?? .success(())
                submission.complete(result, gpuElapsed: .seconds(max(0, command.gpuEndTime - command.gpuStartTime)))
                // User callbacks run after access tokens are returned and outside every Mutex.
                completion?(result.mapError { $0 as Error })
            }
            command.commit()
            return submission
        } catch {
            for buffer in acquired { buffer.endGPUAccess() }
            throw error
        }
    }

    private func validateLayer(
        stateBuffer: MetalBuffer, coefficients: MetalBuffer,
        descriptor: LayerDescriptor, batchSize: Int
    ) throws {
        try stateBuffer.validateElementType(as: Float.self)
        try coefficients.validateElementType(as: Float.self)
        let count = Int(descriptor.count)
        let maximum = descriptor.pattern == 0 ? 256 : 255
        let (portSpan, spanOverflow) = descriptor.count.multipliedReportingOverflow(by: 2)
        let (portEnd, offsetOverflow) = descriptor.offset.addingReportingOverflow(portSpan)
        let (stateCount, stateOverflow) = batchSize.multipliedReportingOverflow(by: 1_024)
        let (stateBytes, byteOverflow) = stateCount.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        let (coefficientBytes, coefficientOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<MZICoefficients>.stride)
        guard descriptor.pattern <= 1, count > 0, count <= maximum,
              descriptor.offset % 2 == descriptor.pattern,
              !spanOverflow, !offsetOverflow, portEnd <= 512,
              batchSize > 0, batchSize <= Int(UInt32.max) / 512,
              !stateOverflow, !byteOverflow,
              !coefficientOverflow, stateBytes <= stateBuffer.logicalByteCount,
              coefficientBytes <= coefficients.logicalByteCount,
              stateBuffer !== coefficients else {
            throw BackendError.invalidLayerDescriptor("pattern, pair count, offset, batch size or buffer capacity is invalid")
        }
    }

    private func validate(gridSize: GridSize) throws {
        let (area, areaOverflow) = gridSize.width.multipliedReportingOverflow(by: gridSize.height)
        let (_, volumeOverflow) = area.multipliedReportingOverflow(by: gridSize.depth)
        guard gridSize.width > 0, gridSize.height > 0, gridSize.depth > 0,
              !areaOverflow, !volumeOverflow else {
            throw BackendError.invalidDispatchGrid(width: gridSize.width, height: gridSize.height, depth: gridSize.depth)
        }
    }
}
