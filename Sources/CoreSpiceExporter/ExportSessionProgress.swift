import Synchronization

/// A synchronous, thread-safe snapshot of completed export points.
public final class ExportSessionProgress: Sendable {
    private let count = Mutex(0)

    public init() {}

    public var pointsWritten: Int { count.withLock { $0 } }

    func increment() { count.withLock { $0 += 1 } }
}
