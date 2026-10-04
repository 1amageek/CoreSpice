/// Local ground and four physical ports plus explicit prime/NQS nodes.
public struct BSIM3Topology: Sendable, Equatable {
    public let nodeCount: Int
    public let drainPrime: Int
    public let sourcePrime: Int
    public let chargeNode: Int
}
