import Synchronization

public final class CancellationToken: Sendable {

    private let _isCancelled = Atomic<Bool>(false)

    public init() {}

    public func cancel() {
        _isCancelled.store(true, ordering: .releasing)
    }

    public var isCancelled: Bool {
        _isCancelled.load(ordering: .acquiring)
    }
}
