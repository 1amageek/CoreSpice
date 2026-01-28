@preconcurrency import Metal
import Synchronization

public final class BufferPool: Sendable {

    private struct PoolState {
        var available: [Int: [MTLBuffer]]
        var allocated: Int
        var maxBytes: Int
    }

    private let device: MTLDevice
    private let state: Mutex<PoolState>

    public init(device: MTLDevice, maxBytes: Int = 256 * 1024 * 1024) {
        self.device = device
        self.state = Mutex(PoolState(
            available: [:],
            allocated: 0,
            maxBytes: maxBytes
        ))
    }

    public func acquire(byteCount: Int, label: String) throws -> MTLBuffer {
        let sizeClass = nextPowerOfTwo(byteCount)

        let cached: MTLBuffer? = state.withLock { poolState in
            if var buffers = poolState.available[sizeClass],
               let buf = buffers.popLast() {
                poolState.available[sizeClass] = buffers
                return buf
            }
            return nil
        }

        if let buffer = cached {
            buffer.label = label
            return buffer
        }

        guard let buffer = device.makeBuffer(length: sizeClass, options: .storageModeShared) else {
            throw BackendError.bufferAllocationFailed(size: byteCount, label: label)
        }
        buffer.label = label
        state.withLock { $0.allocated += sizeClass }
        return buffer
    }

    public func release(_ buffer: MTLBuffer) {
        let sizeClass = buffer.length
        state.withLock { poolState in
            poolState.available[sizeClass, default: []].append(buffer)
        }
    }

    public func drain() {
        state.withLock { poolState in
            poolState.available.removeAll()
            poolState.allocated = 0
        }
    }

    private func nextPowerOfTwo(_ n: Int) -> Int {
        var v = max(n, 256)
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
