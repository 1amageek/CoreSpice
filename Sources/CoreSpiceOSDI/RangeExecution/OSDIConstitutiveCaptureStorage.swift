import OSDIRuntime
import Synchronization

/// Exclusive helper checkout and cleanup-before-refund, including last-owner release.
final class OSDIConstitutiveCaptureStorage: Sendable {
    private struct State: ~Copyable {
        var session: OSDIPrecisionSession?
        var helperLease: (any Sendable)?
        var busy = false
        var closed = false
    }
    static var logicalStateBytes: Int { MemoryLayout<Mutex<State>>.stride }
    private let state: Mutex<State>
    init(session: consuming OSDIPrecisionSession, helperLease: any Sendable) {
        state = Mutex(State(session: .some(consume session), helperLease: helperLease))
    }
    deinit {
        do { try close() }
        catch { preconditionFailure("Unreleased constitutive capture: \(error)") }
    }
    func checkout() throws(OSDIConstitutiveCaptureFailure) -> OSDIPrecisionSession {
        try state.withLock { value throws(OSDIConstitutiveCaptureFailure) in
            guard !value.closed else { throw .closed }
            guard !value.busy else { throw .adapter(.busy) }
            guard let session = value.session.take() else { throw .closed }
            value.busy = true
            return consume session
        }
    }
    func restore(_ session: consuming sending OSDIPrecisionSession) {
        var pending: OSDIPrecisionSession? = .some(consume session)
        state.withLock { value in
            value.session = consume pending
            pending = nil; value.busy = false
        }
    }
    func fail(_ session: consuming OSDIPrecisionSession, primary: any Error) -> OSDIConstitutiveCaptureFailure {
        var current = consume session
        let failure = OSDIConstitutiveCaptureFailure.wrapping(primary)
        do { try current.close() }
        catch { return finish(primary: failure, secondary: error, pending: OSDIConstitutiveCaptureFailure.pending(error)) }
        return finish(primary: failure, secondary: nil, pending: OSDIConstitutiveCaptureFailure.pending(primary))
    }
    func close() throws {
        if state.withLock({ $0.closed }) { return }
        var current = try checkout()
        do { try current.close() }
        catch {
            throw finish(primary: .proof(.runtime(error)), secondary: error,
                pending: OSDIConstitutiveCaptureFailure.pending(error))
        }
        let released = state.withLock { value in
            value.busy = false; value.closed = true
            return value.helperLease.take()
        }
        withExtendedLifetime(released) {}
    }
    private func finish(primary: OSDIConstitutiveCaptureFailure, secondary: OSDIError?,
        pending: OSDIPendingPrecisionCleanup?) -> OSDIConstitutiveCaptureFailure {
        let lease = state.withLock { value in
            value.busy = false; value.closed = true
            return value.helperLease.take()
        }
        if let pending, let lease {
            return .cleanupPending(primary: primary, secondary: secondary,
                owner: OSDIConstitutiveCaptureCleanup(pending: pending, lease: lease))
        }
        if let secondary { return .cleanup(primary: primary, secondary: .proof(.runtime(secondary))) }
        return primary
    }
}
