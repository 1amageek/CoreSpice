import Foundation

public struct ProgressInfo: Sendable {
    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case fractionOutOfRange(Double)

        public var errorDescription: String? {
            switch self {
            case .fractionOutOfRange(let fraction):
                return "Progress fraction must be in 0...1: \(fraction)."
            }
        }
    }

    public let id: AnalysisID
    public let fraction: Double
    public let message: String

    public init(id: AnalysisID, fraction: Double, message: String) throws {
        guard fraction >= 0.0 && fraction <= 1.0 else {
            throw ValidationError.fractionOutOfRange(fraction)
        }
        self.id = id
        self.fraction = fraction
        self.message = message
    }
}
