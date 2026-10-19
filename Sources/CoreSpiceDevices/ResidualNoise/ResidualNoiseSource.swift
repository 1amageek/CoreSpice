import CoreSpiceIR

/// Immutable source order and canonical residual endpoints; nil is ground.
public struct ResidualNoiseSource: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let positive: MNAVariable?
    public let negative: MNAVariable?
    public let unit: ResidualNoiseUnit

    public init(index: Int, name: String, positive: MNAVariable?, negative: MNAVariable?, unit: ResidualNoiseUnit) {
        self.index = index; self.name = name; self.positive = positive; self.negative = negative; self.unit = unit
    }
}
