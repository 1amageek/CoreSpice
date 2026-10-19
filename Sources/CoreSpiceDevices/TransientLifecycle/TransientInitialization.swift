/// Explicit origin of the initial transient solution and native history.
public enum TransientInitialization: Sendable, Equatable {
    case operatingPoint
    case initialConditions
}
