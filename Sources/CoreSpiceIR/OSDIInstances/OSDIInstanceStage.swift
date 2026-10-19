import CoreSpiceOSDIContracts

/// Canonical OSDI inspection stage, independent of executable owner lifetime.
public enum OSDIInstanceStage: Sendable, Equatable {
    case resolved(OSDIResolvedInstance)
    case prepared(OSDIPreparationReceipt)

    public var resolved: OSDIResolvedInstance {
        switch self {
        case .resolved(let value): value
        case .prepared(let receipt): receipt.resolved
        }
    }
}
