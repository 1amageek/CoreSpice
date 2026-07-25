/// An N=512 port photonic MZI mesh.
///
/// The mesh is composed of multiple `MeshLayer` stages, each
/// applying a set of parallel 2x2 MZI transformations.
/// A Clements-style decomposition of a 512x512 unitary matrix
/// requires up to 512 layers alternating between even and odd patterns.
public struct PhotonicMesh512: Sendable {

    /// Fixed number of optical ports.
    public static let portCount = 512

    /// Ordered layers of MZI blocks forming the mesh.
    public let layers: [MeshLayer]

    /// Wavelength model used to adjust phase parameters.
    public let wavelengthModel: WavelengthModel

    public init(layers: [MeshLayer], wavelengthModel: WavelengthModel = WavelengthModel()) {
        self.layers = layers
        self.wavelengthModel = wavelengthModel
    }

    /// The number of layers in this mesh.
    public var layerCount: Int { layers.count }

    /// Maximum number of MZI pairs for a given layer pattern.
    ///
    /// - Even pattern: 256 pairs (ports 0-1, 2-3, ..., 510-511)
    /// - Odd pattern: 255 pairs (ports 1-2, 3-4, ..., 509-510)
    public static func maxPairs(for pattern: LayerPattern) -> Int {
        switch pattern {
        case .even: return portCount / 2       // 256
        case .odd:  return (portCount - 1) / 2 // 255
        }
    }

    public func validate() throws {
        try wavelengthModel.validate()
        for (layerIndex, layer) in layers.enumerated() {
            let maximum = Self.maxPairs(for: layer.pattern)
            guard !layer.blocks.isEmpty, layer.blocks.count <= maximum else {
                throw PhotonicExecutionError.invalidLayer(
                    layer: layerIndex,
                    pairCount: layer.blocks.count,
                    maximum: maximum
                )
            }
            for (blockIndex, block) in layer.blocks.enumerated() {
                if let failure = block.validationFailure() {
                    throw PhotonicExecutionError.invalidMZIBlock(
                        layer: layerIndex,
                        block: blockIndex,
                        reason: failure
                    )
                }
            }
        }
    }
}
