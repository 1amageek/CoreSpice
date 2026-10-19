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
        guard maxBatchSize > 0, portCount > 0, batchSize > 0, batchSize <= maxBatchSize else {
            throw PhotonicExecutionError.invalidGPUResourceRequest("batch or port limit is invalid")
        }
        let (ports, portOverflow) = batchSize.multipliedReportingOverflow(by: portCount)
        let (count, complexOverflow) = ports.multipliedReportingOverflow(by: 2)
        guard !portOverflow, !complexOverflow else {
            throw PhotonicExecutionError.sizeOverflow("GPU state elements")
        }
        return try backend.allocateBuffer(
            type: Float.self,
            count: count,
            label: "photonic_state_\(batchSize)"
        )
    }

    /// Allocate a coefficient buffer for a mesh layer.
    ///
    /// - Parameter pairCount: Number of MZI pairs in the layer.
    /// - Returns: A buffer handle containing eight contiguous Float fields per matrix.
    public func allocateCoefficientsBuffer(pairCount: Int) throws -> Backend.BufferHandle {
        guard (1...256).contains(pairCount) else {
            throw PhotonicExecutionError.invalidGPUResourceRequest("pairCount must be in 1...256")
        }
        return try backend.allocateBuffer(
            type: Float.self,
            count: pairCount * 8,
            label: "photonic_coefficients_\(pairCount)"
        )
    }
}
