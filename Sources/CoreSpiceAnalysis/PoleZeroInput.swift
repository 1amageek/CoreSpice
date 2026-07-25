import CoreSpiceIR

/// Defines the small-signal excitation used by pole-zero analysis.
public enum PoleZeroInput: Sendable, Hashable {
    /// A unit voltage applied between two nodes through the matching independent voltage source.
    case voltage(positive: Node, reference: Node)

    /// A unit current flowing from the positive node to the reference node.
    case current(positive: Node, reference: Node)

    /// A unit voltage applied through an independent voltage source selected by name.
    case voltageSource(name: String)
}
