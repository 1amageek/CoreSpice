import CoreSpiceEvent

public protocol ComputeBackend: Sendable {

    associatedtype BufferHandle: Sendable
    associatedtype KernelHandle: Sendable

    func allocateBuffer<T: Sendable>(
        type: T.Type,
        count: Int,
        label: String
    ) throws -> BufferHandle

    func withMutableContents<T, Result>(
        of buffer: BufferHandle,
        as type: T.Type,
        _ body: (UnsafeMutableBufferPointer<T>) throws -> Result
    ) throws -> Result

    func releaseBuffer(_ buffer: BufferHandle)

    func loadKernel(named name: String) throws -> KernelHandle

    func dispatch(
        kernel: KernelHandle,
        buffers: [BufferHandle],
        gridSize: GridSize,
        observer: EventDispatcher?,
        tag: String
    ) async throws

    func synchronize() async throws

    func prepare(configuration: BackendConfiguration) throws

    func reset()
}
