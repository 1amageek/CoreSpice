/// A single layer of MZI blocks in the photonic mesh.
///
/// Each layer applies a set of parallel 2x2 MZI transformations
/// to adjacent port pairs according to the specified `LayerPattern`.
public struct MeshLayer: Sendable {

    /// The pairing pattern for this layer (even or odd offset).
    public let pattern: LayerPattern

    /// The MZI blocks applied to each pair in order.
    public let blocks: [MZIBlock]

    public init(pattern: LayerPattern, blocks: [MZIBlock]) {
        self.pattern = pattern
        self.blocks = blocks
    }

    /// The number of MZI pairs in this layer.
    public var pairCount: Int { blocks.count }
}
