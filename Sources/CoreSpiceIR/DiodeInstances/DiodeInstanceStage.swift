import CoreSpiceDiodeContracts

/// Canonical inspection stages, separate from executable owner lifetime.
public enum DiodeInstanceStage: Sendable {
    case resolved(ResolvedDiodeInstance)
    case prepared(DiodePreparationReceipt)
    public var resolved: ResolvedDiodeInstance {
        switch self { case .resolved(let value): value; case .prepared(let receipt): receipt.identity.resolved }
    }
}
