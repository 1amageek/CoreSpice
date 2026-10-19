import Synchronization

/// Owns pending submissions and failures until synchronization consumes them.
final class MetalSubmissionTracker: Sendable {
    private struct State {
        var nextID: UInt64 = 0
        var pending: [UInt64: MetalSubmission] = [:]
        var failures: [UInt64: String] = [:]
    }
    private let state = Mutex(State())

    func register(_ submission: MetalSubmission) -> UInt64 {
        state.withLock { value in
            let id = value.nextID
            value.nextID += 1
            value.pending[id] = submission
            return id
        }
    }

    func complete(_ id: UInt64, error: String?) {
        state.withLock { value in
            value.pending.removeValue(forKey: id)
            if let error { value.failures[id] = error }
        }
    }

    func synchronize() async throws {
        let snapshot = state.withLock {
            ($0.nextID, Array($0.pending.values), Array($0.failures.values))
        }
        var reasons = snapshot.2
        for submission in snapshot.1 {
            do { try await submission.wait() }
            catch { reasons.append(error.localizedDescription) }
        }
        let recorded = state.withLock { value in
            let ids = value.failures.keys.filter { $0 < snapshot.0 }
            return ids.sorted().compactMap { value.failures.removeValue(forKey: $0) }
        }
        reasons.append(contentsOf: recorded)
        if !reasons.isEmpty {
            throw BackendError.synchronizationFailed(reasons.joined(separator: "; "))
        }
    }
}
