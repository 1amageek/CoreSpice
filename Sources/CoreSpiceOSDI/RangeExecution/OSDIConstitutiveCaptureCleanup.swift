import OSDIRuntime
import Synchronization

/// Retains helper admission until the exact retryable cleanup completes.
package final class OSDIConstitutiveCaptureCleanup: Sendable {
    private struct State {
        var pending: OSDIPendingPrecisionCleanup?
        var lease: (any Sendable)?
        var closing = false
    }
    static var logicalStateBytes: Int { MemoryLayout<Mutex<State>>.stride }
    private let state: Mutex<State>
    init(pending: OSDIPendingPrecisionCleanup, lease: any Sendable) {
        state = Mutex(State(pending: pending, lease: lease))
    }
    deinit {
        do { try close() }
        catch { preconditionFailure("Unreleased constitutive helper cleanup: \(error)") }
    }
    package func close() throws(OSDIError) {
        let retained = try state.withLock { value throws(OSDIError) -> (OSDIPendingPrecisionCleanup?, (any Sendable)?) in
            guard !value.closing else { throw .libraryInUse }
            value.closing = true
            return (value.pending, value.lease)
        }
        do { try retained.0?.close() }
        catch { state.withLock { $0.closing = false }; throw error }
        state.withLock { value in value.pending = nil; value.lease = nil; value.closing = false }
        // Local retention keeps destruction outside the critical section.
        withExtendedLifetime(retained) {}
    }
}
