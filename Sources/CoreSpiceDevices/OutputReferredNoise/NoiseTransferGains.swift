import CoreSpiceIR

/// Immutable checked full-node gains owned by one analysis-frequency evaluation.
public struct NoiseTransferGains: Sendable {
    private let values: [Node: NoiseTransferGain]
    public init(values: [Node: NoiseTransferGain]) throws {
        for (node, value) in values {
            if node == .ground, value.real != 0 || value.imaginary != 0 { throw NoiseTransferError.nonzeroGroundGain }
            guard value.real.isFinite, value.imaginary.isFinite else { throw NoiseTransferError.nonFiniteGain(node) }
        }
        self.values = values
    }
    public func gain(at node: Node) throws -> NoiseTransferGain {
        if node == .ground { return NoiseTransferGain(real: 0, imaginary: 0) }
        guard let value = values[node] else { throw NoiseTransferError.unknownNode(node) }
        return value
    }
}
