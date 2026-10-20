import OSDIRuntime
import Synchronization

/// Exclusive synchronous checkout, with cleanup completed before helper admission is refunded.
final class OSDISmoothRangeStorage: Sendable {
    private struct State: ~Copyable {
        var session: OSDIPrecisionSession?
        var lease: (any Sendable)?
        var busy = false
        var closed = false
    }
    static var logicalStateBytes: Int { MemoryLayout<Mutex<State>>.stride }
    private let state: Mutex<State>
    init(session: consuming OSDIPrecisionSession, lease: any Sendable) {
        state = Mutex(State(session: .some(consume session), lease: lease))
    }
    deinit {
        do { try close() }
        catch { preconditionFailure("Unreleased smooth range capture: \(error)") }
    }
    func checkout() throws -> OSDIPrecisionSession {
        try state.withLock { value in
            guard !value.closed else { throw OSDISmoothRangeFailure.closed }
            guard !value.busy else { throw OSDISmoothRangeFailure.control(OSDIAdapterFailure.busy) }
            guard let session = value.session.take() else { throw OSDISmoothRangeFailure.closed }
            value.busy = true
            return consume session
        }
    }
    func restore(_ session: consuming sending OSDIPrecisionSession) {
        var pending: OSDIPrecisionSession? = .some(consume session)
        state.withLock { value in value.session = consume pending; pending = nil; value.busy = false }
    }
    func fail(_ session: consuming OSDIPrecisionSession, primary: any Error) -> OSDISmoothRangeFailure {
        var current = consume session
        do { try current.close() }
        catch { return finish(primary: .wrapping(primary), secondary: error, pending: OSDIExecutionOwner.pendingCleanup(error)) }
        return finish(primary: .wrapping(primary), secondary: nil,
            pending: (primary as? OSDIError).flatMap { OSDIExecutionOwner.pendingCleanup($0) })
    }
    func close() throws {
        if state.withLock({ $0.closed }) { return }
        var current = try checkout()
        do { try current.close() }
        catch { throw finish(primary: .runtime(error), secondary: error, pending: OSDIExecutionOwner.pendingCleanup(error)) }
        let released = state.withLock { value in value.busy = false; value.closed = true; return value.lease.take() }
        withExtendedLifetime(released) {}
    }
    private func finish(primary: OSDISmoothRangeFailure, secondary: OSDIError?,
        pending: OSDIPendingPrecisionCleanup?) -> OSDISmoothRangeFailure {
        let lease = state.withLock { value in value.busy = false; value.closed = true; return value.lease.take() }
        if let pending, let lease {
            return .cleanupPending(primary: primary, secondary: secondary,
                owner: OSDIConstitutiveCaptureCleanup(pending: pending, lease: lease))
        }
        if let secondary { return .cleanup(primary: primary, secondary: .runtime(secondary)) }
        return primary
    }
}
