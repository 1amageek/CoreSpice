import CoreSpiceMOSContracts

/// A bounded active binding in a failed condition dependency path.
public struct MOSConditionDependency: Sendable, Hashable {
    public let invocation: UInt64
    public let symbol: MOSSymbolID
}
