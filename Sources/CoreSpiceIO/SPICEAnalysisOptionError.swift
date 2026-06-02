import Foundation

/// Errors raised while translating SPICE controls into analysis configuration.
public enum SPICEAnalysisOptionError: Error, Equatable, LocalizedError {
    case missingOptionValue(name: String)
    case invalidOptionValue(name: String, value: String, reason: String)
    case unsupportedOptionValue(name: String, value: String, reason: String)
    case invalidAnalysisValue(name: String, value: String, reason: String)
    case unsupportedAnalysisFeature(name: String, reason: String)
    case unresolvedParameter(names: String)

    public var errorDescription: String? {
        switch self {
        case .missingOptionValue(let name):
            return "SPICE option '\(name)' requires a value"
        case .invalidOptionValue(let name, let value, let reason):
            return "SPICE option '\(name)' has invalid value '\(value)': \(reason)"
        case .unsupportedOptionValue(let name, let value, let reason):
            return "SPICE option '\(name)=\(value)' is unsupported: \(reason)"
        case .invalidAnalysisValue(let name, let value, let reason):
            return "Analysis value '\(name)=\(value)' is invalid: \(reason)"
        case .unsupportedAnalysisFeature(let name, let reason):
            return "Analysis feature '\(name)' is unsupported: \(reason)"
        case .unresolvedParameter(let names):
            return "Could not resolve SPICE parameter(s): \(names)"
        }
    }
}
