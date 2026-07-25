import Foundation

public enum SPICEOutputProjectionError: Error, Sendable, LocalizedError {
    case emptySelection
    case invalidSavedVariable(String)
    case variableNotFound(String)
    case unsupportedVariable(String)
    case invalidWaveformStorage(point: Int, variable: Int)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Output directives selected no waveform variables."
        case .invalidSavedVariable(let value):
            "Saved output variable '\(value)' is not V(node), V(node,reference), I(device), or all."
        case .variableNotFound(let value):
            "Output variable '\(value)' was not produced by this analysis."
        case .unsupportedVariable(let value):
            "Output variable '\(value)' is not supported by waveform projection."
        case .invalidWaveformStorage(let point, let variable):
            "Waveform storage is missing point \(point), variable \(variable)."
        }
    }
}
