/// A bounded typed view retaining its checked Metal storage lease.
public struct TypedBuffer<Element: GPUBufferElement>: Sendable {
    public let buffer: MetalBuffer
    public let count: Int
    public let label: String

    public init(buffer: MetalBuffer, count: Int, label: String) throws {
        // Validate type, logical capacity and lease state without exposing a pointer.
        try buffer.withMutableContents(as: Element.self, count: count) { _ in }
        self.buffer = buffer
        self.count = count
        self.label = label
    }

    public func withMutableContents<Result>(
        _ body: (UnsafeMutableBufferPointer<Element>) throws -> Result
    ) throws -> Result {
        try buffer.withMutableContents(as: Element.self, count: count, body)
    }

    public func byteLength() throws -> Int {
        let (length, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        guard count >= 0, !overflow else {
            throw BackendError.invalidBufferRequest(
                count: count, stride: MemoryLayout<Element>.stride, label: label)
        }
        return length
    }
}
