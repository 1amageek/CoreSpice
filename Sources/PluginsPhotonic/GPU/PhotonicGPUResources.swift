import CoreSpiceBackend
import SharedTypes

/// Helper for managing GPU buffer allocation in photonic simulations.
///
/// Provides typed allocation methods for the state and coefficient
/// buffers used during MZI mesh dispatch, scoped to a specific
/// backend, batch size, and port count.
public struct PhotonicGPUResources<Backend: PhotonicComputeBackend>: Sendable {

    /// The GPU backend used for allocation and dispatch.
    public let backend: Backend

    /// Maximum number of state vectors in a single batch.
    public let maxBatchSize: Int

    /// Number of optical ports (typically 512).
    public let portCount: Int

    public init(backend: Backend, maxBatchSize: Int = 64, portCount: Int = 512) {
        self.backend = backend
        self.maxBatchSize = maxBatchSize
        self.portCount = portCount
    }

    /// Allocate a state buffer for the given batch size.
    ///
    /// Each element in the batch has `portCount` complex values
    /// stored as interleaved float pairs (real, imag).
    ///
    /// - Parameter batchSize: Number of state vectors in the batch.
    /// - Returns: A buffer handle suitable for GPU dispatch.
    public func allocateStateBuffer(batchSize: Int) throws -> Backend.BufferHandle {
        try backend.allocateBuffer(
            type: Float.self,
            count: batchSize * portCount * 2,
            label: "photonic_state_\(batchSize)"
        )
    }

    /// Allocate a coefficient buffer for a mesh layer.
    ///
    /// - Parameter pairCount: Number of MZI pairs in the layer.
    /// - Returns: A buffer handle for `MZICoefficients` data.
    public func allocateCoefficientsBuffer(pairCount: Int) throws -> Backend.BufferHandle {
        try backend.allocateBuffer(
            type: MZICoefficients.self,
            count: pairCount,
            label: "photonic_coefficients_\(pairCount)"
        )
    }
}
