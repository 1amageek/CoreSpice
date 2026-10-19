@preconcurrency import Metal
import Synchronization

/// A checked lease over shared Metal storage. The raw Metal object stays internal.
/// CPU pointers borrowed through this lease must not escape their access closure.
public final class MetalBuffer: Sendable {
    private struct State {
        var cpuAccess = false
        var gpuAccesses = 0
        var released = false
        var recycled = false
    }

    let ownerID: ObjectIdentifier
    let storage: MTLBuffer
    let logicalByteCount: Int
    public let count: Int
    public let label: String
    private let elementType: ObjectIdentifier
    private let state = Mutex(State())
    private let recycle: @Sendable (MTLBuffer) -> Void

    public var length: Int { storage.length }

    init<Element: GPUBufferElement>(
        storage: MTLBuffer, ownerID: ObjectIdentifier, type: Element.Type, count: Int, label: String,
        recycle: @escaping @Sendable (MTLBuffer) -> Void
    ) {
        self.ownerID = ownerID
        self.storage = storage
        self.count = count
        self.logicalByteCount = count * MemoryLayout<Element>.stride
        self.label = label
        self.elementType = ObjectIdentifier(type)
        self.recycle = recycle
        // The lease owns the raw allocation. Bitwise-copyable values need no
        // destruction, and each new lease binds and initializes its logical range.
        storage.contents().bindMemory(to: type, capacity: count)
            .initialize(repeating: Element.gpuBufferZero, count: count)
    }

    deinit { release() }

    func validateElementType<Element: GPUBufferElement>(as type: Element.Type) throws {
        guard ObjectIdentifier(type) == elementType else {
            throw BackendError.invalidBufferRequest(
                count: count, stride: MemoryLayout<Element>.stride, label: label)
        }
    }

    public func withMutableContents<Element: GPUBufferElement, Result>(
        as type: Element.Type,
        count requestedCount: Int? = nil,
        _ body: (UnsafeMutableBufferPointer<Element>) throws -> Result
    ) throws -> Result {
        let capacity = requestedCount ?? count
        guard ObjectIdentifier(type) == elementType, capacity >= 0, capacity <= count else {
            throw BackendError.invalidBufferRequest(
                count: capacity, stride: MemoryLayout<Element>.stride, label: label)
        }
        try state.withLock { value in
            guard !value.released else { throw BackendError.bufferReleased(label) }
            guard !value.cpuAccess, value.gpuAccesses == 0 else {
                throw BackendError.bufferAccessConflict(label)
            }
            value.cpuAccess = true
        }
        defer { endCPUAccess() }
        // The exclusive state token, not a lock around user code, owns this borrow.
        // The pointer must not escape the closure; storage remains retained by self.
        return try body(UnsafeMutableBufferPointer(
            start: storage.contents().assumingMemoryBound(to: type), count: capacity))
    }

    func beginGPUAccess() throws {
        try state.withLock { value in
            guard !value.released else { throw BackendError.bufferReleased(label) }
            guard !value.cpuAccess else { throw BackendError.bufferAccessConflict(label) }
            value.gpuAccesses += 1
        }
    }

    func endGPUAccess() {
        let shouldRecycle = state.withLock { value in
            value.gpuAccesses -= 1
            return claimRecycle(&value)
        }
        if shouldRecycle { recycle(storage) }
    }

    func release() {
        let shouldRecycle = state.withLock { value in
            value.released = true
            return claimRecycle(&value)
        }
        if shouldRecycle { recycle(storage) }
    }

    private func endCPUAccess() {
        let shouldRecycle = state.withLock { value in
            value.cpuAccess = false
            return claimRecycle(&value)
        }
        if shouldRecycle { recycle(storage) }
    }

    private func claimRecycle(_ value: inout State) -> Bool {
        guard value.released, !value.cpuAccess, value.gpuAccesses == 0,
              !value.recycled else { return false }
        value.recycled = true
        return true
    }
}
