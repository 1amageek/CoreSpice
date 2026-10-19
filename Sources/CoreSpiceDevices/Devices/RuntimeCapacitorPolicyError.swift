/// Invalid operational ceilings for bounded behavioral capacitor preparation.
public enum RuntimeCapacitorPolicyError: Error, Sendable, Equatable {
    case invalidCeiling
    case workOverflow
}
