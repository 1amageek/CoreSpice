import OSDIRuntime

package enum OSDIConstitutiveCaptureFailure: Error, Sendable {
    case missingSnapshot
    case invalidBinding
    case capacityExceeded
    case closed
    case adapter(OSDIAdapterFailure)
    case proof(OSDIPrecisionConstitutiveError)
    case control(any Error)
    indirect case cleanup(primary: Self, secondary: Self)
    indirect case cleanupPending(primary: Self, secondary: OSDIError?, owner: OSDIConstitutiveCaptureCleanup)

    static func wrapping(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        if let failure = error as? OSDIAdapterFailure { return .adapter(failure) }
        if let failure = error as? OSDIPrecisionConstitutiveError { return .proof(failure) }
        return .control(error)
    }
    static func pending(_ error: any Error) -> OSDIPendingPrecisionCleanup? {
        if let error = error as? OSDIError { return OSDIExecutionOwner.pendingCleanup(error) }
        if let error = error as? OSDIPrecisionConstitutiveError {
            switch error {
            case .runtime(let issue): return pending(issue)
            case .cover(let issue): return pending(issue)
            case .cleanup(let primary, let secondary): return pending(primary) ?? pending(secondary)
            default: return nil
            }
        }
        if let error = error as? OSDIPrecisionDecisionCoverError {
            switch error {
            case .runtime(let issue): return pending(issue)
            case .cleanup(let primary, let secondary): return pending(primary) ?? pending(secondary)
            default: return nil
            }
        }
        return nil
    }
}
