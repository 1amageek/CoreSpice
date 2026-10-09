import CoreSpiceIR

/// An ordered independent voltage source terminal pair, never a node measurement.
public struct SPICESupplyBinding: Sendable, Hashable {
    public let sourceName: String
    public let positiveNode: Node
    public let negativeNode: Node
    public init(sourceName: String, positiveNode: Node, negativeNode: Node) {
        self.sourceName = sourceName; self.positiveNode = positiveNode; self.negativeNode = negativeNode
    }
}
