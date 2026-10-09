import Foundation

/// Explicit refusal of incomplete or unverifiable ordinary CLI case publication.
enum CoreSpiceCLICaseError: Error, Sendable, LocalizedError {
    case missingModelOrigin(String)
    case unrecordedModelConsumption(String)
    case incompleteOutput(String)
    case publication(String)
    case unsupportedAnalysis(String)

    var errorDescription: String? {
        switch self {
        case .missingModelOrigin(let name): "Missing captured model origin: \(name)"
        case .unrecordedModelConsumption(let name): "Unrecorded source model consumption: \(name)"
        case .incompleteOutput(let reason): "Incomplete case output: \(reason)"
        case .publication(let reason): "Case publication failed: \(reason)"
        case .unsupportedAnalysis(let name): "Case phase evidence unavailable for analysis: \(name)"
        }
    }
}
