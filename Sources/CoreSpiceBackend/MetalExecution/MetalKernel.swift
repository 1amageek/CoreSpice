@preconcurrency import Metal

/// An immutable kernel identity bound to the backend that compiled its pipeline.
public final class MetalKernel: Sendable {
    public let name: String
    let pipeline: MTLComputePipelineState
    let ownerID: ObjectIdentifier

    init(name: String, pipeline: MTLComputePipelineState, ownerID: ObjectIdentifier) {
        self.name = name
        self.pipeline = pipeline
        self.ownerID = ownerID
    }
}
