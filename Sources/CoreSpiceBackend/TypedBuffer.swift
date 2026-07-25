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

    public func withMutableContents<Result>(
        _ body: (UnsafeMutableBufferPointer<Element>) throws -> Result
    ) rethrows -> Result {
        let ptr = buffer.contents().bindMemory(to: Element.self, capacity: count)
        return try body(UnsafeMutableBufferPointer(start: ptr, count: count))
    }

    public func byteLength() throws -> Int {
        let (length, overflow) = count.multipliedReportingOverflow(
            by: MemoryLayout<Element>.stride
        )
        guard count >= 0, !overflow else {
            throw BackendError.invalidBufferRequest(
                count: count,
                stride: MemoryLayout<Element>.stride,
                label: label
            )
        }
        return length
    }
}
