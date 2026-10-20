import CoreSpiceIR

/// An untrusted oriented request for the actual circuit voltage positive minus reference.
public struct NativePrescribedVoltageFlowVoltagePair: Sendable, Equatable {
    public let positive: Node
    public let reference: Node
    public init(positive: Node, reference: Node) {
        self.positive = positive; self.reference = reference
    }
}
