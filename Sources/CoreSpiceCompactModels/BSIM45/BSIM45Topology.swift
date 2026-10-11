/// Original topology aliases. Ground is zero; the four ports occupy slots 1...4.
public struct BSIM45Topology: Sendable {
    public let nodeCount: Int
    public let drainPrime: Int
    public let sourcePrime: Int
    public let gatePrime: Int
    public let gateMid: Int
    public let bodyPrime: Int
    public let drainBody: Int
    public let sourceBody: Int
    public let chargeNode: Int
    public let noiseRequested: Bool
}
