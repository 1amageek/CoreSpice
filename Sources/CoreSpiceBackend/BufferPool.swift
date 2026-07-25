@preconcurrency import Metal
import Synchronization

public final class BufferPool: Sendable {

    private struct PoolState {
        var available: [Int: [MTLBuffer]]
        var leased: Set<ObjectIdentifier>
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
            leased: [],
            maxBytes: maxBytes
        ))
    }

    public func acquire(byteCount: Int, label: String) throws -> MTLBuffer {
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
                poolState.leased.insert(ObjectIdentifier(buf))
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
        _ = state.withLock {
            $0.leased.insert(ObjectIdentifier(buffer))
        }
        return buffer
    }

    public func release(_ buffer: MTLBuffer) {
        let sizeClass = buffer.length
        state.withLock { poolState in
            guard poolState.leased.remove(ObjectIdentifier(buffer)) != nil else {
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
        state.withLock { poolState in
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
