import SharedTypes
import CoreSpiceEvent

public protocol PhotonicComputeBackend: ComputeBackend {

    func dispatchMZILayer(
        stateBuffer: BufferHandle,
        coefficients: BufferHandle,
        layerDescriptor: LayerDescriptor,
        batchSize: Int,
        observer: EventDispatcher?,
        tag: String
    ) async throws
}
