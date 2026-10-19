@preconcurrency import Metal
import Synchronization

public final class BufferPool: Sendable {

    private struct PoolState {
        var available: [Int: [MTLBuffer]]
        var leased: [ObjectIdentifier: Int]
        var maxBytes: Int
    }

    private let device: MTLDevice
    private let state: Mutex<PoolState>

    public init(device: MTLDevice, maxBytes: Int = 256 * 1024 * 1024) throws {
        guard maxBytes > 0 else {
            throw BackendError.invalidConfiguration("maxBytes must be positive")
        }
        self.device = device
        self.state = Mutex(PoolState(
            available: [:],
            leased: [:],
            maxBytes: maxBytes
        ))
    }

    public func acquire<Element: GPUBufferElement>(
        type: Element.Type, count: Int, label: String
    ) throws -> MetalBuffer {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        guard count > 0, !overflow else {
            throw BackendError.invalidBufferRequest(
                count: count, stride: MemoryLayout<Element>.stride, label: label)
        }
        let storage = try acquireStorage(byteCount: bytes, label: label)
        guard UInt(bitPattern: storage.contents()).isMultiple(of: UInt(MemoryLayout<Element>.alignment)) else {
            recycle(storage)
            throw BackendError.invalidBufferRequest(
                count: count, stride: MemoryLayout<Element>.stride, label: label)
        }
        return MetalBuffer(storage: storage, ownerID: ObjectIdentifier(self), type: type, count: count, label: label) { [self] storage in
            recycle(storage)
        }
    }

    private func acquireStorage(byteCount: Int, label: String) throws -> MTLBuffer {
        guard byteCount > 0 else {
            throw BackendError.invalidBufferRequest(count: byteCount, stride: 1, label: label)
        }
        let sizeClass = try nextPowerOfTwo(byteCount, label: label)

        let cached: MTLBuffer? = state.withLock { poolState in
            guard sizeClass <= poolState.maxBytes else {
                return nil
            }
            if var buffers = poolState.available[sizeClass],
               let buf = buffers.popLast() {
                poolState.available[sizeClass] = buffers
                poolState.leased[ObjectIdentifier(buf)] = sizeClass
                return buf
            }
            return nil
        }

        if let buffer = cached {
            buffer.label = label
            return buffer
        }

        let maximum = state.withLock { $0.maxBytes }
        guard sizeClass <= maximum else {
            throw BackendError.bufferLimitExceeded(
                requested: sizeClass,
                limit: maximum,
                label: label
            )
        }
        guard let buffer = device.makeBuffer(length: sizeClass, options: .storageModeShared) else {
            throw BackendError.bufferAllocationFailed(size: byteCount, label: label)
        }
        buffer.label = label
        try state.withLock {
            guard sizeClass <= $0.maxBytes else {
                throw BackendError.bufferLimitExceeded(
                    requested: sizeClass, limit: $0.maxBytes, label: label)
            }
            $0.leased[ObjectIdentifier(buffer)] = sizeClass
        }
        return buffer
    }

    public func release(_ buffer: MetalBuffer) {
        buffer.release()
    }

    private func recycle(_ buffer: MTLBuffer) {
        let sizeClass = buffer.length
        state.withLock { poolState in
            guard poolState.leased.removeValue(forKey: ObjectIdentifier(buffer)) != nil else {
                return
            }
            if sizeClass <= poolState.maxBytes {
                poolState.available[sizeClass, default: []].append(buffer)
            }
        }
    }

    public func drain() {
        state.withLock { poolState in
            poolState.available.removeAll()
        }
    }

    public func setMaximumBufferSize(_ maxBytes: Int) throws {
        guard maxBytes > 0 else {
            throw BackendError.invalidConfiguration("maxBufferSize must be positive")
        }
        try state.withLock { poolState in
            guard !poolState.leased.values.contains(where: { $0 > maxBytes }) else {
                throw BackendError.invalidConfiguration(
                    "maxBufferSize cannot shrink below an active allocation")
            }
            poolState.maxBytes = maxBytes
            let oversizedClasses = poolState.available.keys.filter { $0 > maxBytes }
            for sizeClass in oversizedClasses {
                poolState.available.removeValue(forKey: sizeClass)
            }
        }
    }

    private func nextPowerOfTwo(_ n: Int, label: String) throws -> Int {
        var v = max(n, 256)
        guard v <= (Int.max >> 1) + 1 else {
            throw BackendError.invalidBufferRequest(count: n, stride: 1, label: label)
        }
        v -= 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
