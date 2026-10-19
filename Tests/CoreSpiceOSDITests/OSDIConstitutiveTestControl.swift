import CoreSpiceCompile
import Synchronization

/// One invocation owner shared by every preparation, instance, box and retained copy.
final class OSDIConstitutiveTestControl: LinearSolverExecutionControlling {
    enum Refusal: Error, Equatable { case work, storage, cancelled }
    struct Counters: Sendable { var work = 0; var live = 0; var peak = 0; var cancelled = false }
    private let state = Mutex(Counters())
    let maximumWork: Int
    let maximumStorage: Int
    let cancelAfterWork: Int?
    init(work: Int = 1_000_000_000, storage: Int = 1_073_741_824, cancelAfterWork: Int? = nil) {
        maximumWork = work; maximumStorage = storage; self.cancelAfterWork = cancelAfterWork
    }
    var counters: Counters { state.withLock { $0 } }
    func cancel() { state.withLock { $0.cancelled = true } }
    func checkpoint(workUnits: Int) throws {
        try state.withLock { value in
            guard !value.cancelled else { throw Refusal.cancelled }
            let (work, overflow) = value.work.addingReportingOverflow(workUnits)
            guard workUnits >= 0, !overflow, work <= maximumWork else { throw Refusal.work }
            if let threshold = cancelAfterWork, work >= threshold {
                value.cancelled = true
                throw Refusal.cancelled
            }
            value.work = work
        }
    }
    func reserveStorage(byteCount: Int) throws -> any Sendable {
        try state.withLock { value in
            guard !value.cancelled else { throw Refusal.cancelled }
            let (bytes, overflow) = value.live.addingReportingOverflow(byteCount)
            guard byteCount >= 0, !overflow, bytes <= maximumStorage else { throw Refusal.storage }
            value.live = bytes; value.peak = max(value.peak, bytes)
        }
        return Lease(owner: self, bytes: byteCount)
    }
    private func release(_ bytes: Int) { state.withLock { $0.live -= bytes } }
    private final class Lease: Sendable {
        let owner: OSDIConstitutiveTestControl
        let bytes: Int
        init(owner: OSDIConstitutiveTestControl, bytes: Int) { self.owner = owner; self.bytes = bytes }
        deinit { owner.release(bytes) }
    }
}
