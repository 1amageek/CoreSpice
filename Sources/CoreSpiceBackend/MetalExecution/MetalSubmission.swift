import Synchronization

/// A completion boundary that includes buffer release and failure recording.
final class MetalSubmission: Sendable {
    private struct State {
        var result: Result<Void, BackendError>?
        var gpuElapsed: Duration = .zero
        var waiters: [CheckedContinuation<Void, Error>] = []
    }
    private let state = Mutex(State())

    var gpuElapsed: Duration { state.withLock { $0.gpuElapsed } }

    func complete(_ result: Result<Void, BackendError>, gpuElapsed: Duration) {
        let waiters = state.withLock { value in
            value.result = result
            value.gpuElapsed = gpuElapsed
            let waiters = value.waiters
            value.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(with: result.mapError { $0 as Error }) }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Void, BackendError>? = state.withLock { value in
                if let result = value.result { return result }
                value.waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result.mapError { $0 as Error }) }
        }
    }
}
