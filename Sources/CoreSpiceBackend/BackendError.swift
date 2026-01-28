public enum BackendError: Error, Sendable {
    case deviceNotFound(String)
    case kernelNotFound(String)
    case bufferAllocationFailed(size: Int, label: String)
    case dispatchFailed(kernel: String, reason: String)
    case synchronizationFailed(String)
    case notPrepared
    case metalNotAvailable
    case shaderCompilationFailed(String)
}
