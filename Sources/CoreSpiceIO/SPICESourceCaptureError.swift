import Foundation

/// Capture admission failures remain distinct from SPICE syntax diagnostics.
public enum SPICESourceCaptureError: Error, Sendable, Equatable, LocalizedError {
    case invalidPolicy
    case totalByteLimitExceeded(limit: UInt64, requested: UInt64)
    case sourceCountLimitExceeded(limit: UInt64)
    case invalidUTF8(path: String)
    case readFailed(path: String, reason: String)
    case sourceChangedDuringRead(path: String)
    case closeFailed(path: String, reason: String)
    case cleanupFailed(primary: String, closeReason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy: return "Source capture limits must be positive, representable, and page bytes must not exceed graph bytes."
        case .totalByteLimitExceeded(let limit, let requested): return "Source graph byte limit \(limit) exceeded by request \(requested)."
        case .sourceCountLimitExceeded(let limit): return "Source graph count limit \(limit) exceeded."
        case .invalidUTF8(let path): return "Source '\(path)' is not valid UTF-8."
        case .readFailed(let path, let reason): return "Failed to capture '\(path)': \(reason)"
        case .sourceChangedDuringRead(let path): return "Source '\(path)' changed size during capture."
        case .closeFailed(let path, let reason): return "Failed to close captured source '\(path)': \(reason)"
        case .cleanupFailed(let primary, let closeReason): return "\(primary); source cleanup also failed: \(closeReason)"
        }
    }
}
