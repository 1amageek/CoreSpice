/// Errors that can occur during photonic mesh execution.
public enum PhotonicExecutionError: Error, Sendable {

    /// The simulation was cancelled via the cancellation token.
    case cancelled

    /// A GPU buffer could not be allocated.
    case bufferAllocationFailed(String)

    /// A GPU kernel dispatch failed.
    case dispatchFailed(String)
}
