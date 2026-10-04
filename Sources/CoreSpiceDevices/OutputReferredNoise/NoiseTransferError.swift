import CoreSpiceIR

public enum NoiseTransferError: Error, Sendable, Equatable {
    case nonzeroGroundGain
    case unknownNode(Node)
    case nonFiniteGain(Node)
}
