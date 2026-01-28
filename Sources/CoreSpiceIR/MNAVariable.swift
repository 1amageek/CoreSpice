/// A variable in the Modified Nodal Analysis system.
///
/// MNA variables are either node voltages (one per non-ground node)
/// or branch currents (one per voltage source or inductor).
public enum MNAVariable: Hashable, Sendable {
    case nodeVoltage(Node)
    case branchCurrent(Branch)
}
