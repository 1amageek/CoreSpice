import CoreSpiceIR

/// One actual resolved node and its finite voltage.
public struct SPICENodeVoltageBinding: Sendable, Hashable {
    public let node: Node
    public let voltage: Double
    internal init(node: Node, voltage: Double) { self.node = node; self.voltage = voltage }
}
