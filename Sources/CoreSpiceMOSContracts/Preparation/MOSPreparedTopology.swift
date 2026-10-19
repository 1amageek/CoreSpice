/// Fixed native classical MOS topology: four physical ports and no auxiliary nodes.
/// OSDI models use their independently prepared topology contract.
public struct MOSPreparedTopology: Sendable, Hashable {
    public var localNodeCount: Int { 4 }
    public var auxiliaryNodeCount: Int { 0 }

    public init() {}
}
