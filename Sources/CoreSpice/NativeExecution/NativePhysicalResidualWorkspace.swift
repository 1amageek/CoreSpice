import CoreSpiceOSDI
import Synchronization

/// Exclusively loans reusable sum buffers without holding a lock across device calls.
internal final class NativePhysicalResidualWorkspace: Sendable {
    struct Buffers: Sendable {
        var sums: [Double]
        var corrections: [Double]
    }
    private let storage: Mutex<Buffers?>

    init(count: Int) {
        storage = Mutex(Buffers(sums: [Double](repeating: 0, count: count),
            corrections: [Double](repeating: 0, count: count)))
    }

    func withBuffers(_ body: (inout Buffers) throws -> Void) throws {
        var buffers = try storage.withLock { value in
            guard let available = value else { throw OSDIAdapterFailure.busy }
            value = nil
            return available
        }
        defer { storage.withLock { $0 = buffers } }
        for index in buffers.sums.indices { buffers.sums[index] = 0; buffers.corrections[index] = 0 }
        try body(&buffers)
    }
}
