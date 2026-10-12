import CoreSpiceDiodeContracts

/// Canonical source resolution stage; numerical preparation is a separate capability.
public enum DiodeInstanceStage: Sendable {
    case resolved(ResolvedDiodeInstance)

    public var resolved: ResolvedDiodeInstance {
        switch self { case .resolved(let value): value }
    }
}
