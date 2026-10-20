import OSDIRuntime

public enum OSDISmoothRangeFailure: Error, Sendable {
    case missingSnapshot, invalidBinding, explicitTimeInput, closed
    case runtime(OSDIError)
    case control(any Error)
    indirect case cleanup(primary: Self, secondary: Self)
    indirect case cleanupPending(primary: Self, secondary: OSDIError?, owner: OSDIConstitutiveCaptureCleanup)

    static func wrapping(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        if let failure = error as? OSDIError { return .runtime(failure) }
        return .control(error)
    }
}
