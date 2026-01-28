@preconcurrency import Metal

public struct TypedBuffer<Element: Sendable>: Sendable {

    public let buffer: MTLBuffer
    public let count: Int
    public let label: String

    public init(buffer: MTLBuffer, count: Int, label: String) {
        self.buffer = buffer
        self.count = count
        self.label = label
    }

    public var contents: UnsafeMutableBufferPointer<Element> {
        let ptr = buffer.contents().bindMemory(to: Element.self, capacity: count)
        return UnsafeMutableBufferPointer(start: ptr, count: count)
    }

    public var byteLength: Int {
        count * MemoryLayout<Element>.stride
    }
}
