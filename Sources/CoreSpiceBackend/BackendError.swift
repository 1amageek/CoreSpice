import Foundation

public enum BackendError: Error, Sendable, LocalizedError {
    case deviceNotFound(String)
    case kernelNotFound(String)
    case bufferAllocationFailed(size: Int, label: String)
    case dispatchFailed(kernel: String, reason: String)
    case synchronizationFailed(String)
    case notPrepared
    case metalNotAvailable
    case shaderCompilationFailed(String)
    case preferredDeviceMismatch(requested: String, active: String)
    case invalidConfiguration(String)
    case invalidBufferRequest(count: Int, stride: Int, label: String)
    case bufferLimitExceeded(requested: Int, limit: Int, label: String)
    case invalidDispatchGrid(width: Int, height: Int, depth: Int)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let name):
            "Metal device was not found: \(name)."
        case .kernelNotFound(let name):
            "Metal kernel was not found: \(name)."
        case .bufferAllocationFailed(let size, let label):
            "Metal buffer allocation failed for \(label) with \(size) bytes."
        case .dispatchFailed(let kernel, let reason):
            "Metal dispatch failed for \(kernel): \(reason)"
        case .synchronizationFailed(let reason):
            "Metal synchronization failed: \(reason)"
        case .notPrepared:
            "Compute backend has not been prepared."
        case .metalNotAvailable:
            "Metal is not available on this system."
        case .shaderCompilationFailed(let reason):
            "Metal shader compilation failed: \(reason)"
        case .preferredDeviceMismatch(let requested, let active):
            "Metal backend is bound to \(active), but configuration requested \(requested)."
        case .invalidConfiguration(let reason):
            "Compute backend configuration is invalid: \(reason)"
        case .invalidBufferRequest(let count, let stride, let label):
            "Buffer request for \(label) is invalid (count: \(count), stride: \(stride))."
        case .bufferLimitExceeded(let requested, let limit, let label):
            "Buffer request for \(label) requires \(requested) bytes, exceeding the \(limit)-byte limit."
        case .invalidDispatchGrid(let width, let height, let depth):
            "Dispatch grid dimensions must be positive (width: \(width), height: \(height), depth: \(depth))."
        }
    }
}
