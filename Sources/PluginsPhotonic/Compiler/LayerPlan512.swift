import SharedTypes

/// GPU execution plan for a compiled photonic mesh.
///
/// Contains pre-computed MZI transfer-matrix coefficients in
/// structure-of-arrays layout suitable for GPU dispatch.
/// Each layer maps to a `LayerDescriptor` that tells the kernel
/// the pair offset, count, and pattern.
public struct LayerPlan512: Sendable {

    /// Total number of layers in the plan.
    public let layerCount: Int

    /// Pre-computed coefficients indexed as [layerIndex][pairIndex].
    public let coefficients: [[MZICoefficients]]

    /// One descriptor per layer describing offset, count, and pattern.
    public let descriptors: [LayerDescriptor]

    public init(
        layerCount: Int,
        coefficients: [[MZICoefficients]],
        descriptors: [LayerDescriptor]
    ) {
        self.layerCount = layerCount
        self.coefficients = coefficients
        self.descriptors = descriptors
    }
}
