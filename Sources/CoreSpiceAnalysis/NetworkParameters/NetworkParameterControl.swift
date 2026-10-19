import CoreSpiceCompile
import CoreSpiceEvent
import Synchronization

/// Run-local live-payload accounting; upstream reservations are never refunded twice.
final class NetworkParameterControl: LinearSolverExecutionControlling, AnalysisResultStorageAccounting, Sendable {
    private let bytes = Mutex(0)
    let maximumBytes: Int
    let budget: TransientExecutionBudget
    let cancellation: CancellationToken
    let upstream: (any AnalysisResultStorageAccounting)?

    init(maximumBytes: Int, budget: TransientExecutionBudget, cancellation: CancellationToken,
         upstream: (any AnalysisResultStorageAccounting)?) {
        self.maximumBytes = maximumBytes
        self.budget = budget
        self.cancellation = cancellation
        self.upstream = upstream
    }

    var liveBytes: Int { bytes.withLock { $0 } }

    func checkpoint(workUnits: Int) throws {
        try checkCancellation()
        try budget.chargeWork(workUnits)
        try checkCancellation()
    }

    func checkCancellation() throws {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
    }

    func reserveStorage(byteCount: Int) throws -> any Sendable {
        guard let count = UInt64(exactly: byteCount) else {
            throw TransientExecutionError.arithmeticOverflow("network temporary bytes")
        }
        return try reserveTemporaryBytes(count)
    }

    func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
        try checkCancellation()
        guard let count = Int(exactly: byteCount), count >= 0 else {
            throw TransientExecutionError.arithmeticOverflow("network temporary bytes")
        }
        try bytes.withLock { current in
            let next = try TransientExecutionBudget.add(current, count, "network live bytes")
            guard next <= maximumBytes else {
                throw NetworkParameterError.temporaryStorageExceeded(limit: maximumBytes, requested: next)
            }
            current = next
        }
        // The lease immediately owns the debit, including any upstream refusal.
        let lease = Lease(owner: self, count: count)
        lease.upstream = try upstream?.reserveTemporaryBytes(byteCount)
        try checkCancellation()
        return lease
    }

    func reserveResultScalars(_ capacity: Int) throws {
        try checkCancellation()
        try upstream?.reserveResultScalars(capacity)
    }

    private func refund(_ count: Int) { bytes.withLock { $0 -= count } }

    private final class Lease: Sendable {
        let owner: NetworkParameterControl
        let count: Int
        // Initialized before publication; stored in Mutex to keep every target's isolation identical.
        private let held = Mutex<(any Sendable)?>(nil)
        var upstream: (any Sendable)? {
            get { held.withLock { $0 } }
            set { held.withLock { $0 = newValue } }
        }
        init(owner: NetworkParameterControl, count: Int) { self.owner = owner; self.count = count }
        deinit { owner.refund(count) }
    }
}
