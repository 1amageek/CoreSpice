/// Operational policy construction failures before runtime device binding.
public enum RuntimeResistorPolicyError: Error, Sendable {
    case invalidCeiling
    case workOverflow
}
