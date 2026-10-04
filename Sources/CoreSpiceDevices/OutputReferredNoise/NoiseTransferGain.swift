/// Complex V/A response from a unit node-current injection to the output.
public struct NoiseTransferGain: Sendable, Equatable {
    public let real: Double
    public let imaginary: Double
    public init(real: Double, imaginary: Double) {
        self.real = real; self.imaginary = imaginary
    }
}
