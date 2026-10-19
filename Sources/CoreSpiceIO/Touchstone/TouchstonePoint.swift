import CoreSpiceAnalysis

/// A single physical-frequency matrix, independent of a circuit operating point.
public struct TouchstonePoint: Sendable, Equatable {
    public let frequencyHz: Double
    public let matrix: NetworkParameterMatrix

    public init(frequencyHz: Double, matrix: NetworkParameterMatrix) throws {
        guard frequencyHz.isFinite, frequencyHz >= 0 else {
            throw TouchstoneError.invalidData("Frequency must be finite and nonnegative")
        }
        self.frequencyHz = frequencyHz
        self.matrix = matrix
    }
}
