/// Exact native local-role slots; the maximum non-ground slot is localNodeCount.
public struct MOSPreparedTopology: Sendable, Hashable {
    public let localNodeCount: Int
    public let drainPrime: Int
    public let sourcePrime: Int
    public let gatePrime: Int
    public let gateMid: Int
    public let bodyPrime: Int
    public let drainBody: Int
    public let sourceBody: Int
    public let chargeNode: Int
    public var auxiliaryNodeCount: Int { localNodeCount - 4 }

    public init(localNodeCount: Int, drainPrime: Int, sourcePrime: Int, gatePrime: Int,
                gateMid: Int, bodyPrime: Int, drainBody: Int, sourceBody: Int, chargeNode: Int)
        throws(MOSPreparationFailure) {
        // Eight roles can reference at most eight distinct private slots.
        guard localNodeCount >= 4, localNodeCount <= 12 else { throw .invalidTopology }
        func inRange(_ slot: Int) -> Bool { slot >= 0 && slot <= localNodeCount }
        guard inRange(drainPrime), inRange(sourcePrime), inRange(gatePrime), inRange(gateMid),
              inRange(bodyPrime), inRange(drainBody), inRange(sourceBody), inRange(chargeNode) else {
            throw .invalidTopology
        }
        if localNodeCount > 4 {
            for slot in 5...localNodeCount {
                guard drainPrime == slot || sourcePrime == slot || gatePrime == slot || gateMid == slot ||
                      bodyPrime == slot || drainBody == slot || sourceBody == slot || chargeNode == slot else {
                    throw .invalidTopology
                }
            }
        }
        self.localNodeCount = localNodeCount; self.drainPrime = drainPrime; self.sourcePrime = sourcePrime
        self.gatePrime = gatePrime; self.gateMid = gateMid; self.bodyPrime = bodyPrime
        self.drainBody = drainBody; self.sourceBody = sourceBody; self.chargeNode = chargeNode
    }
}
